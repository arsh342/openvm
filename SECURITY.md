# Security policy

Please do not report security problems in public issues.

Use GitHub's private reporting: go to the **Security** tab of this repository and choose **Report a vulnerability**. Include the steps to reproduce the problem, and what an attacker could do with it.

## Scope

The most important boundary is between a guest and the Mac: a guest is not trusted, so a way for a guest to reach the host beyond what the user shared is a security bug.

Known trade-offs are documented in the README, and are not vulnerabilities:

* Windows sound is optional, and it puts the guest in Test Mode.
* Windows guests have a default account password, which users should change.
