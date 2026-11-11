; Hotspots often count as "Public" networks, so allow Pasa on every profile.
!macro NSIS_HOOK_POSTINSTALL
  nsExec::Exec 'netsh advfirewall firewall add rule name="Pasa" dir=in action=allow program="$INSTDIR\pasa.exe" enable=yes profile=any'
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::Exec 'netsh advfirewall firewall delete rule name="Pasa"'
!macroend
