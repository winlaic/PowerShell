// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Collections.Generic;
using System.Diagnostics;

namespace System.Management.Automation
{
    // Owns Process references only while their native processors are alive. Never kills
    // a process group: the shell and its children can share the same Unix process group.
    internal sealed class ForegroundNativeProcesses
    {
        private readonly object _sync = new object();
        private readonly HashSet<Process> _processes = new HashSet<Process>();
        private bool _terminating;

        internal void Register(Process process)
        {
            lock (_sync)
            {
                if (_terminating)
                {
                    Kill(process);
                    throw new PipelineStoppedException();
                }

                _processes.Add(process);
            }
        }

        internal void Unregister(Process process)
        {
            lock (_sync)
            {
                _processes.Remove(process);
            }
        }

        internal void RequestTermination()
        {
            lock (_sync)
            {
                _terminating = true;
            }
        }

        internal void KillAll()
        {
            lock (_sync)
            {
                foreach (Process process in _processes)
                {
                    Kill(process);
                }
            }
        }

        private static void Kill(Process process)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (System.ComponentModel.Win32Exception)
            {
                KillRoot(process);
            }
            catch (System.AggregateException)
            {
                // Some descendants may have changed ownership or already exited.
                KillRoot(process);
            }
            catch (System.InvalidOperationException)
            {
                // The process already exited.
            }
            catch (System.Exception)
            {
                KillRoot(process);
            }
        }

        private static void KillRoot(Process process)
        {
            try
            {
                process.Kill();
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // Permission changes can prevent termination.
            }
            catch (System.InvalidOperationException)
            {
            }
            catch (System.Exception)
            {
            }
        }
    }
}
