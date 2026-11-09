// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace Microsoft.PowerShell.Commands
{
    // Shared validation stays internal; the public API consists of the three cmdlets.
    internal static class ConsoleCommandLineHookCommandHelper
    {
        internal static ConsoleCommandLineHookRegistry GetRegistry(PSCmdlet cmdlet)
        {
            var host = ConsoleHost.HookHost;
            if (host == null || cmdlet.Context.CurrentRunspace != Runspace.PrimaryRunspace || !host.CommandLineHooksSupported ||
                host.IsRunspacePushed || host.IsNested ||
                !ExperimentalFeature.IsEnabled(ConsoleCommandLineHookRegistry.FeatureName))
            {
                cmdlet.ThrowTerminatingError(new ErrorRecord(
                    new NotSupportedException(ConsoleHostStrings.CommandLineHooksUnsupportedHost),
                    "ConsoleCommandLineHooksUnsupportedHost", ErrorCategory.NotImplemented, null));
            }

            return host.CommandLineHooks;
        }
    }

    /// <summary>Registers independently owned synchronous console lifecycle handlers.</summary>
    [Experimental(ConsoleCommandLineHookRegistry.FeatureName, ExperimentAction.Show)]
    [Cmdlet(VerbsLifecycle.Register, "PSConsoleCommandLineHook")]
    [OutputType(typeof(ConsoleCommandLineHook))]
    public sealed class RegisterPSConsoleCommandLineHookCommand : PSCmdlet
    {
        /// <summary>Gets or sets a descriptive registration label.</summary>
        [Parameter(Mandatory = true)]
        [ValidateNotNullOrEmpty]
        public string Name { get; set; }

        /// <summary>Gets or sets the handler called before user execution.</summary>
        [Parameter]
        [ValidateNotNull]
        public ScriptBlock Starting { get; set; }

        /// <summary>Gets or sets the handler called after execution or pre-execution cancellation.</summary>
        [Parameter]
        [ValidateNotNull]
        public ScriptBlock Finished { get; set; }

        /// <summary>Registers the handlers and returns the registration metadata.</summary>
        protected override void ProcessRecord()
        {
            var registry = ConsoleCommandLineHookCommandHelper.GetRegistry(this);
            if (Starting == null && Finished == null)
            {
                ThrowTerminatingError(new ErrorRecord(
                    new ArgumentException(ConsoleHostStrings.CommandLineHooksHandlerRequired),
                    "ConsoleCommandLineHookHandlerRequired", ErrorCategory.InvalidArgument, Name));
            }

            WriteObject(registry.Register(Name, Starting, Finished));
        }
    }

    /// <summary>Lists registrations or queries bounded hook diagnostics.</summary>
    [Experimental(ConsoleCommandLineHookRegistry.FeatureName, ExperimentAction.Show)]
    [Cmdlet(VerbsCommon.Get, "PSConsoleCommandLineHook", DefaultParameterSetName = "Registrations")]
    [OutputType(typeof(ConsoleCommandLineHook), typeof(ConsoleCommandLineHookDiagnostic))]
    public sealed class GetPSConsoleCommandLineHookCommand : PSCmdlet
    {
        /// <summary>Gets or sets the switch to query diagnostics rather than registrations.</summary>
        [Parameter(Mandatory = true, ParameterSetName = "Diagnostics")]
        public SwitchParameter Diagnostic { get; set; }

        /// <summary>Writes an immutable snapshot in registration or diagnostic order.</summary>
        protected override void ProcessRecord()
        {
            var registry = ConsoleCommandLineHookCommandHelper.GetRegistry(this);
            WriteObject(Diagnostic ? (object)registry.GetDiagnostics() : Array.ConvertAll(registry.Snapshot(), entry => entry.Metadata), enumerateCollection: true);
        }
    }

    /// <summary>Removes one registration without affecting other plugins.</summary>
    [Experimental(ConsoleCommandLineHookRegistry.FeatureName, ExperimentAction.Show)]
    [Cmdlet(VerbsLifecycle.Unregister, "PSConsoleCommandLineHook", SupportsShouldProcess = true)]
    public sealed class UnregisterPSConsoleCommandLineHookCommand : PSCmdlet
    {
        /// <summary>Gets or sets registration IDs, accepting registration objects from the pipeline.</summary>
        [Parameter(Mandatory = true, ValueFromPipelineByPropertyName = true)]
        [ValidateNotNullOrEmpty]
        public Guid[] Id { get; set; }

        /// <summary>Removes the registrations; missing IDs are an idempotent no-op.</summary>
        protected override void ProcessRecord()
        {
            var registry = ConsoleCommandLineHookCommandHelper.GetRegistry(this);
            foreach (Guid id in Id)
            {
                if (ShouldProcess(id.ToString()))
                {
                    registry.Unregister(id);
                }
            }
        }
    }
}
