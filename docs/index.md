
Guild Operators provides community-maintained deployment, management, and
monitoring tools for Cardano node operators. `cardano-node` (`cnode`) remains
the default implementation. Experimental Dingo and Amaru relay deployments are
also available for the networks documented in their implementation guides.
All three profiles include gLiveView; its adapter identifies the selected node
implementation and hides measurements that implementation does not export.
These tools simplify recurring tasks, but operating infrastructure on a
financial network still requires professional system administration and
security skills:

- Understand system architecture, setup, and operations.
- Know how to secure and maintain a public server.
- For cnode pool operation, be comfortable with `cardano-cli` and first
  practise on a test network without wrapper scripts.
- Read the documentation and disclaimers. The tools do not replace an
  environment-specific security and operations plan.
- Keep payment, stake, and pool cold keys offline. Copy only the minimum
  operational hot-key material required by a block producer to that online
  host.

Documentation, testing, code, and other contributions are welcome. The project
aims to maintain one shared, reviewable source of operational guidance.

#### Support {docsify-ignore}

The [Telegram Support channel](https://t.me/CardanoKoios/9759) is used to announce new releases and changes to the code base. This is also the place to ask general questions regarding the documentation and scripts on this site.  

To report bugs, documentation problems, or feature requests, use the
[GitHub issue chooser](https://github.com/cardano-community/guild-operators/issues/new/choose).

#### Getting Started {docsify-ignore}

Use the sidebar to navigate through the topics. The
[folder structure in Basics](basics.md#folder-structure) shows the default
cnode deployment. Dingo and Amaru use the implementation-specific layouts
linked from that section.

!!! question ""
    Again, Feedback/Contribution and ownership of tasks is *always welcome*. If you're interested in collaborating regularly, make a start - and you should be part of the guild already :smile:.
