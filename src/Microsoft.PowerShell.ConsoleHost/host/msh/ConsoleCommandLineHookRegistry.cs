// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Threading;

namespace Microsoft.PowerShell
{
    internal sealed class ConsoleCommandLineHookRegistry
    {
        internal const string FeatureName = "PSConsoleCommandLineHooks";
        private readonly object _sync = new object();
        private ConsoleCommandLineHookRegistration[] _registrations = Array.Empty<ConsoleCommandLineHookRegistration>();
        private readonly Queue<ConsoleCommandLineHookDiagnostic> _diagnostics = new Queue<ConsoleCommandLineHookDiagnostic>();
        private const int DiagnosticCapacity = 128;

        internal ConsoleCommandLineHook Register(string name, ScriptBlock starting, ScriptBlock finished)
        {
            var hook = new ConsoleCommandLineHookRegistration(name, starting, finished);
            lock (_sync)
            {
                var updated = new ConsoleCommandLineHookRegistration[_registrations.Length + 1];
                Array.Copy(_registrations, updated, _registrations.Length);
                updated[updated.Length - 1] = hook;
                Volatile.Write(ref _registrations, updated);
            }

            return hook.Metadata;
        }

        internal void Unregister(Guid id)
        {
            lock (_sync)
            {
                Volatile.Write(ref _registrations, Array.FindAll(_registrations, hook => hook.Metadata.Id != id));
            }
        }

        internal void Clear()
        {
            lock (_sync)
            {
                Volatile.Write(ref _registrations, Array.Empty<ConsoleCommandLineHookRegistration>());
                _diagnostics.Clear();
            }
        }

        // Arrays are never mutated after publication; callers must not expose the array itself.
        internal ConsoleCommandLineHookRegistration[] Snapshot() => Volatile.Read(ref _registrations);

        internal void Record(Guid registrationId, Guid invocationId, string phase, string errorId, Exception exception)
        {
            lock (_sync)
            {
                if (_diagnostics.Count == DiagnosticCapacity)
                {
                    _diagnostics.Dequeue();
                }

                _diagnostics.Enqueue(new ConsoleCommandLineHookDiagnostic(
                    registrationId, invocationId, phase, errorId, exception?.GetType().FullName));
            }
        }

        internal ConsoleCommandLineHookDiagnostic[] GetDiagnostics()
        {
            lock (_sync)
            {
                return _diagnostics.ToArray();
            }
        }
    }
}
