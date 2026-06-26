# 1. Record architecture decisions

Date: 2026-06-26

## Status

Accepted

## Context

This package makes several non-obvious calls (build shape, auth topology, addon-vs-bundle, media
routing, memory sizing). The next maintainer — or a future me — needs to know *why*, not just *what*,
so decisions are not silently reversed.

## Decision

We record each significant decision as a short ADR in `docs/decisions/NNNN-title.md`, using a
lightweight Nygard-style format (Context / Decision / Consequences). The verified-vs-assumed log in
`docs/PACKAGING-NOTES.md` carries the empirical evidence; ADRs carry the reasoning.

## Consequences

ADRs are append-only history. Superseding a decision means adding a new ADR that references the old
one and flipping the old one's status to "Superseded", not editing the original.
