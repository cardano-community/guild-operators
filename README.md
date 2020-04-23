# Important:
- Intention: Test pre-releases in a controlled environment to prevent connecting with incompatible versions on IOHK network and also have a stable environment to learn/study.
- Remember: To avoid spamming logs of nodes of other network, please ensure to not re-use IP-port combination between different networks
- Also Remember: Before starting node for the first time, ensure respective storage/db folders are empty
- Cap: Pools intending to run their stake pool have been distributed 1000000000 Test Lovelaces, would be great if we use it as a cap.
- For helper scripts, these are either copies - or small modifications of IOHK provided helper scripts to keep them compatible with versions here.

# Cardano Node (Haskell - PBFT) Testnet details

Check Setup and connection details [here]

# Jormungandr (Rust) Testnet details - Enabled upon request

## v0.8.19

### Trusted Peers
```
  trusted_peers:
    #rdlrt
    - address: /ip4/88.99.83.86/tcp/4007
      id: 0add359010d13fc0e9d403c822887638969276aaedccd1f4
```

[here]: https://cardano-community.github.io/guild-operators
