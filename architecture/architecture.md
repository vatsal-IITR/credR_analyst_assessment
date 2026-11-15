# Architecture diagram

Rendered natively by GitHub / VS Code / most markdown viewers.

```mermaid
flowchart LR
    subgraph SRC[Source systems]
        S1[Dialer / telephony vendors x15]
        S2[WhatsApp + SMS providers]
        S3[Field app]
        S4[Core loan system: accounts, status]
        S5[Payment gateway / bank]
        S6[CRM: agents, campaigns, PTP, complaints]
    end

    subgraph RAW[Raw - immutable, partitioned by ingest date]
        R1[(files / events as received)]
    end

    subgraph STG[Staging]
        T1[typed, + _src_row, _ingested_at]
        C0{{data contracts: schema, status codes, timezone}}
    end

    subgraph CLEAN[Clean]
        CL1[dedupe, timestamp to IST, code mapping]
        RJ[(rejects + reason)]
        LOG[(dq.cleaning_log)]
    end

    subgraph GOLD[Golden]
        G1[fact_payment]
        G2[fact_contact]
        G3[dim_agent]
        G4[account_month]
        G5[payment_attribution]
    end

    subgraph FEAT[Feature / analysis]
        F1[did_panel]
        F2[touch_lift_weekly]
        F3[forensics tables]
    end

    subgraph MET[Metrics]
        M1[metrics.monthly - per-day, validated PTP]
        M2[metrics.monthly_history - restatements]
    end

    subgraph OUT[Consumption]
        D1[Executive dashboard - one screen]
        D2[Analysis notebook]
        D3[Alerts: DQ + anomaly]
    end

    S1 --> R1
    S2 --> R1
    S3 --> R1
    S4 --> R1
    S5 --> R1
    S6 --> R1
    R1 --> T1
    C0 -. validates .-> T1
    T1 --> CL1
    CL1 --> RJ
    CL1 --> LOG
    CL1 --> G1
    CL1 --> G2
    CL1 --> G3
    G1 --> G4
    G2 --> G4
    G1 --> G5
    G2 --> G5
    G4 --> F1
    G2 --> F2
    G1 --> F2
    CL1 --> F3
    G4 --> M1
    G1 --> M1
    M1 --> M2
    M1 --> D1
    F1 --> D2
    F3 --> D2
    LOG --> D3
    M2 --> D3
    D3 -. pages owner .-> S5
```

## Daily run

```mermaid
sequenceDiagram
    participant O as Orchestrator
    participant L as Loader
    participant Q as DQ checks
    participant T as SQL layers
    participant M as Metrics
    participant B as Dashboard
    O->>L: load last 7 days of each source (idempotent merge)
    L->>Q: contract + row-count checks
    alt error-level failure
        Q-->>O: stop, page owner, keep yesterday's dashboard
    else pass / warn
        Q->>T: clean -> golden -> feature
        T->>Q: key, FK, reconciliation checks
        Q->>M: build metrics, snapshot into monthly_history
        M->>B: refresh, show data-as-of and restated months
    end
```

## How to run the implemented part

```
python pipeline/run_pipeline.py --export     # raw CSV -> stg -> clean -> golden -> metrics -> forensics -> analysis
python pipeline/build_notebook.py            # executes the notebook
python pipeline/build_dashboard.py           # writes dashboard/index.html
```
