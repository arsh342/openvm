# Contributing to openVM

Thanks for helping. Bug reports, fixes and improvements are all welcome.

## Before you start

For anything large, open an issue first, so we can agree on the approach. Read [docs/architecture.md](docs/architecture.md) to see where a change belongs.

## Making a change

1. Keep each change to one purpose.
2. Run `make format` and `make check`.
3. If the change touches a guest, the boot path or an install script, run the matching real smoke. See [docs/testing.md](docs/testing.md).
4. Update the docs in the same change when behaviour changes.

## Code style

* The host is Swift, and guest agents and boot code are C. Please do not add other languages.
* Keep one responsibility per file.
* A new feature follows the path in the architecture doc, not a new one.
* Comments explain why, not what. Project history belongs in commit messages.
* Treat everything from a guest as untrusted, and add a hostile-input test for new agent input.
* A new message type takes the next free number. Numbers are never reused.

## Reporting a bug

Include your Mac model, macOS version, guest, the command you ran, and the output. The guest's console log is at `~/.openvm/<name>.console.log`. For Windows guests, the agent's log is `C:\openvm\agent.log`.

## License

By contributing, you agree that your work is licensed under the Apache License 2.0.
