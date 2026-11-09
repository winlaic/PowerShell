// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

namespace System.Management.Automation
{
    // Scoped to a primary-runspace execution, never inferred from variable assignment.
    internal sealed class ConsoleCommandLineExitCodes
    {
        internal int? NativeExitCode { get; private set; }

        internal int? ScriptExitCode { get; private set; }

        internal void RecordNative(int code) => NativeExitCode = code;

        internal void RecordScript(int code) => ScriptExitCode = code;
    }
}
