// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Microsoft.PowerShell
{
    internal sealed partial class ConsoleHost
    {
        private ForegroundCommandExecution _foregroundCommand;
#if UNIX
        private PosixSignalRegistration _forceKillSignal;

        private void BindForceKillHandler()
        {
            if ((Platform.IsLinux || Platform.IsMacOS) && !s_cpp.NonInteractive &&
                ExperimentalFeature.IsEnabled("PSConsoleForceKillOnCtrlZ"))
            {
                _forceKillSignal = PosixSignalRegistration.Create(PosixSignal.SIGTSTP, context =>
                {
                    // The enabled interactive shell must not suspend itself, even at a prompt.
                    context.Cancel = true;
                    lock (hostGlobalLock)
                    {
                        if (!IsNested && !InDebugMode && !IsRunspacePushed)
                        {
                            _foregroundCommand?.RequestTermination();
                        }
                    }
                });
            }
        }
#endif

        // The host publishes one scope at a time. Signal receipt captures this scope's
        // pipeline, never CurrentExecutor at some later point in the worker thread.
        internal sealed class ForegroundCommandExecution : IDisposable
        {
            private readonly ConsoleHost _host;
            private readonly Executor _executor;
            private readonly System.Management.Automation.ExecutionContext _context;
            private readonly ForegroundNativeProcesses _processes = new ForegroundNativeProcesses();
            private readonly ForegroundNativeProcesses _previous;
            private readonly byte[] _terminalState;
            private Pipeline _pipeline;
            private Task _termination;
            private bool _completed;

            internal static ForegroundCommandExecution Start(ConsoleHost host, Executor executor, bool nested)
            {
#if UNIX
                if (host._forceKillSignal != null && !nested && !host.InDebugMode && !host.IsRunspacePushed &&
                    host.Runspace == Runspace.PrimaryRunspace && host.Runspace is LocalRunspace)
                {
                    return new ForegroundCommandExecution(host, executor);
                }
#endif
                return null;
            }

            private ForegroundCommandExecution(ConsoleHost host, Executor executor)
            {
                _host = host;
                _executor = executor;
                _context = host.Runspace.ExecutionContext;
                _previous = _context.ForegroundNativeProcesses;
                _context.ForegroundNativeProcesses = _processes;
                _terminalState = UnixTerminalState.Capture();
                lock (host.hostGlobalLock)
                {
                    executor.ForegroundCommand = this;
                    host._foregroundCommand = this;
                }
            }

            internal void BindPipeline(Pipeline pipeline)
            {
                lock (_host.hostGlobalLock)
                {
                    if (_termination != null)
                    {
                        throw new PipelineStoppedException();
                    }

                    _pipeline = pipeline;
                }
            }

            // Called under hostGlobalLock. The signal callback never waits for a pipeline,
            // process enumeration, or the ordinary Ctrl+C cancellation thread.
            internal void RequestTermination()
            {
                if (_completed || _termination != null)
                {
                    return;
                }

                _processes.RequestTermination();
                Executor hookExecutor = _host._activeCommandLine?.RequestCancellation();
                Pipeline target = _host._activeCommandLine != null
                    ? hookExecutor?.PipelineAtSignalReceipt : _pipeline;
                _termination = Task.Run(() =>
                {
                    try
                    {
                        _processes.KillAll();
                    }
                    finally
                    {
                        try
                        {
                            target?.StopAsync();
                        }
                        catch (InvalidOperationException)
                        {
                            // A pipeline can complete between signal receipt and StopAsync.
                        }
                        catch (InvalidPipelineStateException)
                        {
                        }
                    }
                });
            }

            internal void Complete()
            {
                Task termination;
                lock (_host.hostGlobalLock)
                {
                    if (_completed)
                    {
                        return;
                    }

                    _completed = true;
                    _host._foregroundCommand = null;
                    _executor.ForegroundCommand = null;
                    termination = _termination;
                }

                try
                {
                    termination?.GetAwaiter().GetResult();
                }
                finally
                {
                    _context.ForegroundNativeProcesses = _previous;
                    if (termination != null)
                    {
                        _context.QuestionMarkVariableValue = false;
                        UnixTerminalState.Restore(_terminalState);
                    }
                }
            }

            public void Dispose() => Complete();
        }

        // An opaque, oversized termios buffer avoids assuming Linux's or macOS's layout.
        // Only bytes initialized by tcgetattr are consumed by the matching tcsetattr.
        private static class UnixTerminalState
        {
            internal static byte[] Capture()
            {
#if UNIX
                if (!Console.IsInputRedirected)
                {
                    byte[] state = new byte[512];
                    if (tcgetattr(0, state) == 0)
                    {
                        return state;
                    }
                }
#endif
                return null;
            }

            internal static void Restore(byte[] state)
            {
#if UNIX
                if (state != null)
                {
                    tcsetattr(0, 0, state); // TCSANOW on Linux and macOS.
                }
#endif
            }

#if UNIX
            [DllImport("libc", SetLastError = true)]
            private static extern int tcgetattr(int fd, [Out] byte[] state);

            [DllImport("libc", SetLastError = true)]
            private static extern int tcsetattr(int fd, int action, byte[] state);
#endif
        }
    }
}
