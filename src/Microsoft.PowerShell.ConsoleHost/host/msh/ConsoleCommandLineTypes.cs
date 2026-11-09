// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;

namespace Microsoft.PowerShell
{
    /// <summary>The terminal outcome of a complete console submission.</summary>
    public enum ConsoleCommandLineOutcome
    {
        /// <summary>The final PowerShell execution status was successful.</summary>
        Succeeded,

        /// <summary>Execution failed.</summary>
        Failed,

        /// <summary>The submission was cancelled, possibly before execution.</summary>
        Cancelled,

        /// <summary>Complete input contained syntax errors.</summary>
        ParseError,

        /// <summary>The user requested that the shell exit.</summary>
        ShellExit,
    }

    /// <summary>Immutable metadata for a complete local console submission.</summary>
    public class ConsoleCommandLineEventArgs : EventArgs
    {
        internal ConsoleCommandLineEventArgs(Guid id, string line, DateTimeOffset acceptedAt, DateTimeOffset timestamp)
        {
            InvocationId = id;
            CommandLine = line;
            ProcessId = Environment.ProcessId;
            AcceptedAt = acceptedAt;
            Timestamp = timestamp;
        }

        /// <summary>Gets the identifier shared by this submission's notifications.</summary>
        public Guid InvocationId { get; }

        /// <summary>Gets the complete unexpanded input, preserving newlines.</summary>
        public string CommandLine { get; }

        /// <summary>Gets the PowerShell host PID, not a child process PID.</summary>
        public int ProcessId { get; }

        /// <summary>Gets when complete input was accepted, in UTC.</summary>
        public DateTimeOffset AcceptedAt { get; }

        /// <summary>Gets when this notification was created, in UTC.</summary>
        public DateTimeOffset Timestamp { get; }
    }

    /// <summary>Immutable results captured before finish handlers run.</summary>
    public sealed class ConsoleCommandLineFinishedEventArgs : ConsoleCommandLineEventArgs
    {
        internal ConsoleCommandLineFinishedEventArgs(
            Guid id, string line, DateTimeOffset acceptedAt, DateTimeOffset timestamp,
            DateTimeOffset? startedAt, DateTimeOffset? endedAt, TimeSpan? duration,
            ConsoleCommandLineOutcome outcome, int? nativeCode, int? scriptCode, int? shellCode)
            : base(id, line, acceptedAt, timestamp)
        {
            ExecutionStartedAt = startedAt;
            ExecutionEndedAt = endedAt;
            Duration = duration;
            Outcome = outcome;
            NativeExitCode = nativeCode;
            ScriptExitCode = scriptCode;
            ShellExitCode = shellCode;
        }

        /// <summary>Gets whether the user pipeline was invoked.</summary>
        public bool ExecutionStarted => ExecutionStartedAt.HasValue;

        /// <summary>Gets the UTC time immediately before invocation, or null if not invoked.</summary>
        public DateTimeOffset? ExecutionStartedAt { get; }

        /// <summary>Gets the UTC time when execution and cancellation cleanup completed.</summary>
        public DateTimeOffset? ExecutionEndedAt { get; }

        /// <summary>Gets monotonic execution duration excluding hooks, or null if not invoked.</summary>
        public TimeSpan? Duration { get; }

        /// <summary>Gets the terminal result of this submission.</summary>
        public ConsoleCommandLineOutcome Outcome { get; }

        /// <summary>Gets the last observed native exit code in this execution, or null.</summary>
        public int? NativeExitCode { get; }

        /// <summary>Gets the last observed script exit code in this execution, or null.</summary>
        public int? ScriptExitCode { get; }

        /// <summary>Gets the requested shell exit code, or null if no shell exit was requested.</summary>
        public int? ShellExitCode { get; }
    }

    /// <summary>Public registration metadata; handlers are not exposed.</summary>
    public sealed class ConsoleCommandLineHook
    {
        internal ConsoleCommandLineHook(string name, bool hasStartingHandler, bool hasFinishedHandler)
        {
            Id = Guid.NewGuid();
            Name = name;
            HasStartingHandler = hasStartingHandler;
            HasFinishedHandler = hasFinishedHandler;
        }

        /// <summary>Gets the registration ID used for unregistration.</summary>
        public Guid Id { get; }

        /// <summary>Gets the caller-supplied label. Labels need not be unique.</summary>
        public string Name { get; }

        /// <summary>Gets whether a start handler is registered.</summary>
        public bool HasStartingHandler { get; }

        /// <summary>Gets whether a finish handler is registered.</summary>
        public bool HasFinishedHandler { get; }
    }

    internal sealed class ConsoleCommandLineHookRegistration
    {
        internal ConsoleCommandLineHookRegistration(string name, System.Management.Automation.ScriptBlock starting, System.Management.Automation.ScriptBlock finished)
        {
            Metadata = new ConsoleCommandLineHook(name, starting != null, finished != null);
            Starting = starting;
            Finished = finished;
        }

        internal ConsoleCommandLineHook Metadata { get; }

        internal System.Management.Automation.ScriptBlock Starting { get; }

        internal System.Management.Automation.ScriptBlock Finished { get; }
    }

    /// <summary>A bounded in-memory diagnostic for a hook failure; does not include command text.</summary>
    public sealed class ConsoleCommandLineHookDiagnostic
    {
        internal ConsoleCommandLineHookDiagnostic(Guid registrationId, Guid invocationId, string phase, string errorId, string exceptionType)
        {
            RegistrationId = registrationId;
            InvocationId = invocationId;
            Phase = phase;
            ErrorId = errorId;
            ExceptionType = exceptionType;
            Timestamp = DateTimeOffset.UtcNow;
        }

        /// <summary>Gets the failed registration's ID.</summary>
        public Guid RegistrationId { get; }

        /// <summary>Gets the submission's ID.</summary>
        public Guid InvocationId { get; }

        /// <summary>Gets Starting or Finished.</summary>
        public string Phase { get; }

        /// <summary>Gets a host-defined diagnostic identifier, without command text or exception message.</summary>
        public string ErrorId { get; }

        /// <summary>Gets the exception type, without retaining the exception or session.</summary>
        public string ExceptionType { get; }

        /// <summary>Gets the UTC time the diagnostic was collected.</summary>
        public DateTimeOffset Timestamp { get; }
    }
}
