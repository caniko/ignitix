hostName: hostKey: let
  # The alias is independent of route address/port and safe for known_hosts.
  alias = "ignitix-bootstrap-${builtins.substring 0 32 (builtins.hashString "sha256" hostName)}";
  knownHosts = builtins.toFile "ignitix-bootstrap-known-hosts" "${alias} ${hostKey}\n";
in [
  "StrictHostKeyChecking=yes"
  "UserKnownHostsFile=${knownHosts}"
  "GlobalKnownHostsFile=/dev/null"
  "HostKeyAlias=${alias}"
  "HostKeyAlgorithms=ssh-ed25519"
  "CheckHostIP=no"
  "VerifyHostKeyDNS=no"
  "KnownHostsCommand=none"
  "NoHostAuthenticationForLocalhost=no"
  "UpdateHostKeys=no"
  "BatchMode=yes"
  "PreferredAuthentications=publickey"
  "PubkeyAuthentication=yes"
  "PasswordAuthentication=no"
  "KbdInteractiveAuthentication=no"
  "ControlMaster=no"
  "ControlPath=none"
]
