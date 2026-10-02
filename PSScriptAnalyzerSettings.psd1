@{
    Severity = @(
        'Error'
        'Warning'
    )

    # These planning functions create in-memory models. Export is the only
    # public function in this slice that changes filesystem state, and it
    # implements SupportsShouldProcess.
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
