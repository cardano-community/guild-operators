## Guild Operators' Repository

A place for node operators to contribute deployment, management, and monitoring
tools to the Cardano ecosystem.

## Documentation and guides

The [Guild Operators documentation](https://cardano-community.github.io/guild-operators)
covers the default `cardano-node` (`cnode`) deployment and the compatible
operator tools. Experimental Dingo relays and block producers, plus Amaru
relays, are also documented for supported test networks. The common gLiveView
dashboard supports all three implementations through normalized,
availability-driven metrics, and Dingo includes experimental CNTools support
through its cardano-cli-compatible local socket.

These scripts simplify recurring work; they do not replace the skills needed
to operate infrastructure on a financial network:

- Understand Linux systems administration and architecture.
- Secure and maintain every public server.
- For cnode pool operation, be comfortable with `cardano-cli` and practise on
  a test network without wrapper scripts.
- Read the documentation, release notes, and security warnings before
  deploying or upgrading.
- Keep payment, stake, and pool cold keys offline. Place only the minimum
  operational hot-key material required by a block producer on an online host.

The [Community Support FAQ](https://cardano-community.github.io/support-faq)
contains broader Cardano how-to guides, including wallet, explorer, and
delegation topics.

The [Cardano Community concepts site](https://cardano-community.github.io/concepts)
collects educational articles about blockchain fundamentals.

## Support

The [Telegram announcement and support channel](https://t.me/CardanoKoios/9759)
announces releases and accepts general questions about the documentation and
scripts.

Report script or documentation problems and feature proposals through the
[GitHub issue chooser](https://github.com/cardano-community/guild-operators/issues/new/choose).
