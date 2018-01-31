get_version:
  local.net.cli:
    - tgt: vsrxnapalm
    - arg:
      - "show version"
