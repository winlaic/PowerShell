// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Diagnostics;
using System.Management.Automation;
using System.Management.Automation.Internal;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace Microsoft.PowerShell
{
    internal sealed partial class ConsoleHost
    {
        internal ConsoleCommandLineHookRegistry CommandLineHooks { get; } = new ConsoleCommandLineHookRegistry();

        internal bool CommandLineHooksSupported => !s_cpp.NonInteractive && !InDebugMode;

        internal static ConsoleHost HookHost => s_theConsoleHost;

        // Accessed under hostGlobalLock by signal receipt and phase changes.
        private CommandLineExecution _activeCommandLine;

        private sealed class ExitCodeSuspension : IDisposable
        {
            private readonly System.Management.Automation.ExecutionContext _context;
            private readonly ConsoleCommandLineExitCodes _saved;

            internal ExitCodeSuspension(System.Management.Automation.ExecutionContext context)
            {
                _context = context;
                _saved = context.ConsoleCommandLineExitCodes;
                context.ConsoleCommandLineExitCodes = null;
            }

            public void Dispose() => _context.ConsoleCommandLineExitCodes = _saved;
        }

        private static IDisposable SuspendCommandLineExitCodes(ConsoleHost host) =>
            host.Runspace is System.Management.Automation.Runspaces.LocalRunspace
                ? new ExitCodeSuspension(host.Runspace.ExecutionContext) : null;

        // Direct invocation by type, never registered or exported. Catch flow control before
        // the pipeline interprets a handler's 'exit' as a request to exit the shell.
        [Cmdlet(VerbsLifecycle.Invoke, "ConsoleCommandLineCallback")]
        private sealed class InvokeConsoleCommandLineCallbackCommand : Cmdlet
        {
            public InvokeConsoleCommandLineCallbackCommand()
            {
            }

            [Parameter]
            public ScriptBlock Handler { get; set; }

            [Parameter]
            public ConsoleCommandLineEventArgs Notification { get; set; }

            [Parameter]
            public Action<Exception> Failure { get; set; }

            protected override void ProcessRecord()
            {
                try
                {
                    Handler.InvokeWithPipe(
                        useLocalScope: true,
                        errorHandlingBehavior: ScriptBlock.ErrorHandlingBehavior.SwallowErrors,
                        dollarUnder: null, input: null, scriptThis: null,
                        outputPipe: new Pipe { NullPipe = true }, invocationInfo: null,
                        args: new object[] { Notification });
                }
                catch (Exception exception)
                {
                    Failure(exception);
                }
            }
        }

        private sealed class CommandLineExecution : IDisposable
        {
            private readonly ConsoleHost _host;
            private readonly Runspace _runspace;
            private readonly ConsoleCommandLineHookRegistration[] _hooks;
            private readonly Guid _id = Guid.NewGuid();
            private readonly string _line;
            private readonly DateTimeOffset _acceptedAt = DateTimeOffset.UtcNow;
            private readonly bool _parseError;
            private readonly ConsoleCommandLineExitCodes _codes = new ConsoleCommandLineExitCodes();
            private CancellationTokenSource _phaseCancellation = new CancellationTokenSource();
            private Executor _executor;
            private bool _cancelled;
            private bool _executionCancelled;
            private bool _completed;
            private DateTimeOffset? _startedAt;
            private long _startTimestamp;
            private PipelineStateInfo _pipelineState;

            internal static CommandLineExecution Start(ConsoleHost host, string line, bool nested)
            {
                if (nested || s_cpp.NonInteractive || host.IsRunspacePushed ||
                    host.Runspace != Runspace.PrimaryRunspace ||
                    host.Runspace is not System.Management.Automation.Runspaces.LocalRunspace)
                {
                    return null;
                }

                var hooks = host.CommandLineHooks.Snapshot();
                if (hooks.Length == 0)
                {
                    return null;
                }

                Parser.ParseInput(line, out _, out ParseError[] errors);
                foreach (ParseError error in errors)
                {
                    if (error.IncompleteInput)
                    {
                        return null;
                    }
                }

                var execution = new CommandLineExecution(host, line, hooks, errors.Length != 0);
                lock (host.hostGlobalLock)
                {
                    host._activeCommandLine = execution;
                }

                return execution;
            }

            private CommandLineExecution(ConsoleHost host, string line, ConsoleCommandLineHookRegistration[] hooks, bool parseError)
            {
                _host = host;
                _runspace = host.Runspace;
                _line = line;
                _hooks = hooks;
                _parseError = parseError;
            }

            // Called under hostGlobalLock at signal receipt, before asynchronous cancellation.
            internal Executor RequestCancellation()
            {
                _cancelled = true;
                _phaseCancellation.Cancel();
                return _executor;
            }

            private void WaitForCancellation()
            {
                Thread thread;
                lock (_host.hostGlobalLock)
                {
                    thread = _host._breakHandlerThread;
                }

                thread?.Join();
            }

            internal void Execute(Executor executor, out Exception exception)
            {
                exception = null;
                InvokeHandlers(starting: true, new ConsoleCommandLineEventArgs(_id, _line, _acceptedAt, DateTimeOffset.UtcNow));
                WaitForCancellation();
                lock (_host.hostGlobalLock)
                {
                    if (_cancelled)
                    {
                        _executionCancelled = true;
                        _runspace.ExecutionContext.QuestionMarkVariableValue = false;
                        return;
                    }

                    _executor = executor;
                    executor.CommandLineCancellation = _phaseCancellation.Token;
                }

                var context = _runspace.ExecutionContext;
                var previous = context.ConsoleCommandLineExitCodes;
                context.ConsoleCommandLineExitCodes = _codes;
                executor.CommandLineInvoking = () =>
                {
                    // Complete syntax errors notify, but do not count as user execution.
                    if (!_parseError)
                    {
                        _startedAt = DateTimeOffset.UtcNow;
                        _startTimestamp = Stopwatch.GetTimestamp();
                    }
                };
                try
                {
                    var options = Executor.ExecutionOptions.AddOutputter | Executor.ExecutionOptions.AddToHistory;
                    if (_host.IsRunningAsync)
                    {
                        executor.ExecuteCommandAsync(_line, out exception, options);
                    }
                    else
                    {
                        executor.ExecuteCommand(_line, out exception, options);
                    }
                }
                catch (Exception error)
                {
                    exception = error;
                }
                finally
                {
                    _pipelineState = executor.LastPipelineState;
                    context.ConsoleCommandLineExitCodes = previous;
                    executor.CommandLineInvoking = null;
                    executor.CommandLineCancellation = default;
                    WaitForCancellation();
                    lock (_host.hostGlobalLock)
                    {
                        _executionCancelled = _cancelled;
                        _executor = null;
                    }
                }
            }

            internal void Complete(Exception exception)
            {
                if (_completed)
                {
                    return;
                }

                _completed = true;
                lock (_host.hostGlobalLock)
                {
                    // Freeze the user result and enter the finish phase atomically with
                    // signal receipt. A late execution signal must not be lost here.
                    _executionCancelled |= _cancelled;
                    _phaseCancellation.Dispose();
                    _phaseCancellation = new CancellationTokenSource();
                    _cancelled = false;
                    _executor = null;
                }

                DateTimeOffset endedAt = DateTimeOffset.UtcNow;
                TimeSpan? duration = _startedAt.HasValue ? Stopwatch.GetElapsedTime(_startTimestamp) : null;
                var context = _runspace.ExecutionContext;
                ConsoleCommandLineOutcome outcome;
                int? shellCode = null;
                if (_host._setShouldExitCalled)
                {
                    outcome = ConsoleCommandLineOutcome.ShellExit;
                    shellCode = _host._exitCodeFromRunspace;
                }
                else if (_executionCancelled || _pipelineState?.State == PipelineState.Stopped ||
                    exception is PipelineStoppedException || exception is OperationCanceledException)
                {
                    outcome = ConsoleCommandLineOutcome.Cancelled;
                }
                else if (_parseError || exception is ParseException)
                {
                    outcome = ConsoleCommandLineOutcome.ParseError;
                }
                else
                {
                    outcome = exception == null && _pipelineState?.State == PipelineState.Completed && context.QuestionMarkVariableValue
                        ? ConsoleCommandLineOutcome.Succeeded : ConsoleCommandLineOutcome.Failed;
                }

                var notification = new ConsoleCommandLineFinishedEventArgs(
                    _id, _line, _acceptedAt, endedAt, _startedAt, _startedAt.HasValue ? endedAt : null,
                    duration, outcome, _codes.NativeExitCode, _codes.ScriptExitCode, shellCode);
                InvokeHandlers(starting: false, notification);
                WaitForCancellation();
            }

            private void InvokeHandlers(bool starting, ConsoleCommandLineEventArgs notification)
            {
                foreach (var hook in _hooks)
                {
                    var handler = starting ? hook.Starting : hook.Finished;
                    lock (_host.hostGlobalLock)
                    {
                        if (_cancelled)
                        {
                            return;
                        }
                    }

                    if (handler != null)
                    {
                        InvokeHandler(hook, handler, starting ? "Starting" : "Finished", notification);
                    }
                }
            }

            private void InvokeHandler(ConsoleCommandLineHookRegistration hook, ScriptBlock handler, string phase, ConsoleCommandLineEventArgs notification)
            {
                var context = _runspace.ExecutionContext;
                bool success = context.QuestionMarkVariableValue;
                var lastExitVariable = context.EngineSessionState.GetVariable("global:LASTEXITCODE");
                object lastExitCode = lastExitVariable?.Value;
                var previousSink = context.ErrorRecordingOverride;
                var previousCodes = context.ConsoleCommandLineExitCodes;
                Action<Exception> failure = exception => _host.CommandLineHooks.Record(hook.Metadata.Id, _id, phase, "CallbackException", exception);
                context.ErrorRecordingOverride = error =>
                {
                    if (error is ErrorRecord record)
                    {
                        _host.CommandLineHooks.Record(hook.Metadata.Id, _id, phase, "CallbackError", record.Exception);
                    }
                    else if (error is Exception exception)
                    {
                        failure(exception);
                    }
                };
                context.ConsoleCommandLineExitCodes = null;
                try
                {
                    using Pipeline pipeline = _runspace.CreatePipeline();
                    var info = new CmdletInfo("Invoke-ConsoleCommandLineCallback", typeof(InvokeConsoleCommandLineCallbackCommand), null, null, context);
                    var command = new Command(info);
                    command.Parameters.Add("Handler", handler);
                    command.Parameters.Add("Notification", notification);
                    command.Parameters.Add("Failure", failure);
                    pipeline.Commands.Add(command);
                    var executor = new Executor(_host, useNestedPipelines: false, isPromptFunctionExecutor: false);
                    lock (_host.hostGlobalLock)
                    {
                        _executor = executor;
                        executor.CommandLineCancellation = _phaseCancellation.Token;
                    }

                    executor.ExecuteCommandHelper(pipeline, out Exception error, Executor.ExecutionOptions.None);
                    if (error != null)
                    {
                        failure(error);
                    }
                }
                catch (Exception exception)
                {
                    failure(exception);
                }
                finally
                {
                    try
                    {
                        if (lastExitVariable == null)
                        {
                            context.EngineSessionState.RemoveVariable("global:LASTEXITCODE", force: true);
                        }
                        else
                        {
                            context.EngineSessionState.SetVariable(SpecialVariables.LastExitCodeVarPath, lastExitCode, true, true, CommandOrigin.Internal);
                        }
                    }
                    catch (Exception exception)
                    {
                        _host.CommandLineHooks.Record(hook.Metadata.Id, _id, phase, "ExitCodeRestoreFailed", exception);
                    }
                    finally
                    {
                        context.ErrorRecordingOverride = previousSink;
                        context.ConsoleCommandLineExitCodes = previousCodes;
                        context.QuestionMarkVariableValue = success;
                        WaitForCancellation();
                        lock (_host.hostGlobalLock)
                        {
                            _executor = null;
                        }
                    }
                }
            }

            public void Dispose()
            {
                try
                {
                    if (!_completed)
                    {
                        Complete(new InvalidOperationException());
                    }
                }
                finally
                {
                    lock (_host.hostGlobalLock)
                    {
                        _host._activeCommandLine = null;
                        _phaseCancellation.Dispose();
                    }
                }
            }
        }
    }
}
