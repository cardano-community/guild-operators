---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Deployment details**

- OS and version: [e.g. Ubuntu 24.04]
- Deployment type: [host or Docker]
- Guild Operators branch/tag:
- Node implementation: [cnode, Dingo, or Amaru]
- Network: [mainnet, guild, preprod, or preview as applicable]
- Product/script version:
- Node version: [output of `cardano-node version`, `dingo version`, or
  `amaru --version`]

If this is a current Guild deployment, include the non-sensitive metadata from
`${NODE_HOME}/.deployment.json`. Review it before posting and remove any local
details you do not want to share:

```bash
jq '{schemaVersion, deploymentStatus, implementation, network, branch,
     serviceName, nodeVersion, targetNodeVersion, metricsProvider,
     capabilities}' "${NODE_HOME}/.deployment.json"
```

**Additional context**
Add any other context about the problem here.
