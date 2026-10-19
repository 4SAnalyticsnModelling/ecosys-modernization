"""Reader for audited canonical exports; native output adapters must preserve this contract.

Each object has key (complete ordered coordinate tuple), time (numeric elapsed time),
periods {seasonal,annual,cumulative}, and values (all data columns with canonical units).
Export provenance and native-column completeness require separate source review.
"""
import json

def rows(path, role):
    with path.open() as f:
        for line in f:
            yield json.loads(line)
