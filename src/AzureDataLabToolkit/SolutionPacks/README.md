# Solution packs

The alpha ships the `SqlVmBackupRestore` solution-pack contract. It
adds a pinned dbatools catalog dependency when backup storage is selected and
plans a manual, preview-first restore script. Rendering is local-only;
uploading the script and running a restore remain unavailable.

Future solution packs can compose providers, capabilities, catalog selections,
and probes without becoming deployment engines.
