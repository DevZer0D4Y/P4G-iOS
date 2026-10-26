"""The Persona 4 Golden builds this port supports, by the NSO build ID of `main`.

Code-level fixes (tools/patches_p4g.py) are keyed by build: an unknown build is refused rather than generated
without them, since their addresses would point at the wrong instructions.
"""
import sys

BUILDS = {
    # build ID (first 40 hex digits, upper case): (label, patches key)
    'C433D980688380A642C086072F620928DF7D6320': ('1.0.0', 'v1_0_0'),
}


def select(build_id):
    key = build_id.upper()[:40].ljust(40, '0')
    if key not in BUILDS:
        sys.exit(f'main: unknown game build {build_id}; supported: ' +
                 ', '.join(f'{v[0]} ({k[:16]})' for k, v in BUILDS.items()))
    return key, BUILDS[key]
