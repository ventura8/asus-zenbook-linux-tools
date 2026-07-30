"""Repository-local sitecustomize module.

When the repository root is on ``sys.path``, this module shadows any
distro-provided ``sitecustomize`` so tests and tooling do not pick up
distribution path-mutation side effects. The module is intentionally inert
(does not mutate ``sys.path``).
"""

SITECUSTOMIZE_LOADED = True
