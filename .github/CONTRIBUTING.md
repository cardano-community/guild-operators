# Contributing Guidelines

Thank you for contributing to Guild Operators. Contributions accepted by this
project are released under the repository's open-source license. Keep
discussion respectful, focused, and useful to operators.

## Submitting a pull request

- Fork and clone the repository.
- Make a focused change and add or update tests and documentation where
  applicable.
- Run the relevant checks under `files/tests/` and the shell lint workflow
  locally when possible.
- Do not commit private keys, credentials, node databases, or generated
  operator state.
- Push the branch to your fork and submit a pull request.

Here are a few things you can do that will increase the likelihood of your pull request being accepted:

- Follow standards for style and code quality (see below).
- Explain compatibility implications for cnode, Dingo, and Amaru. Do not imply
  that a cnode-only helper supports an alternate implementation unless that
  behavior has been verified.
- Write tests for behavior changes.
- Keep your change as focused as possible. If there are multiple changes you would like to make
  that are not dependent upon each other, consider submitting them as separate pull requests.
- Write a [good commit message](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html).

## Code Style Guidelines

This project uses EditorConfig to maintain consistent coding styles across different developers, editors, and IDEs.

The `.editorconfig` file in this repository defines the style rules. To get the most out of EditorConfig, make sure your editor is configured to use it. This will automatically apply the project's style rules when you edit/save files.

## Resources

- [How to Contribute to Open Source](https://opensource.guide/how-to-contribute/)
- [Using Pull Requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests)
- [Guild Operators documentation](https://cardano-community.github.io/guild-operators)
