# Security Policy

## Supported scope

Security reports are welcome for the current code in this repository, especially:

- the relay upload, download, delete, and cleanup paths
- the shared blob framing and integrity logic
- the browser-side WASM encryption and decryption bridge
- the CLI relay and direct-transfer flows

## How to report a vulnerability

Please do not file public GitHub issues for suspected vulnerabilities.

Instead, report them privately to the project maintainer with:

- a description of the issue
- affected components and files if known
- reproduction steps or a proof of concept
- impact assessment
- any suggested mitigation if you have one

If a dedicated security contact address is added later, this file should be updated to point to it explicitly.

## What to expect

- Good-faith reports will be reviewed as quickly as possible.
- You may be asked for clarification or a smaller reproduction case.
- Fixes may land privately first and be disclosed after a patch is available.

## Disclosure preference

Please give the project reasonable time to investigate and ship a fix before public disclosure.

## Current security posture

This project is still evolving. If you are evaluating it for real-world use, review the code and threat model yourself instead of treating the repository as audited software.
