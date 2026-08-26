# The Metadata-Driven Sales ETL Framework — Explained End to End

This is a step-by-step walkthrough of how the pipeline actually works, in the order data travels: ADLS Gen2 → SQL staging → validation → deduplication → the star schema → reporting views. It complements `PROJECT2_IMPLEMENTATION.md` (the build report) and `SQL_PROCEDURES_REFERENCE.md` (proc API reference) — this file is the "why does it work this way" narrative.

A rendered version with diagrams is also published as an interactive artifact: https://claude.ai/code/artifact/b346bbf5-49fe-4f92-be5e-fd1ce37d54c4

---

## 1. One generic pipeline, not four hand-built ones

The naive way to build this would be four separate ADF pipelines — one that copies Product files, one for Customer, one for Store, one for SalesOrder — each with its own hardcoded table names and column lists. That works, but every new source file means opening ADF Studio and building a new pipeline.

Instead, this framework has exactly **two** pipelines. One of them, `PL_MetaDriven_ProcessEntity`, doesn't know what a "Product" or a "SalesOrder" is at all — it only knows how to read a row out of a control table called `meta.EntityConfig` and follow instructions: which file to copy, which staging table to land it in, which rule set to validate against, which stored procedure to call to load it. Adding a fifth source (say, a `Region` dimension next quarter) means writing one row of metadata and one load procedure — never touching the pipeline canvas.

**Why this matters:** the entire point of a "metadata-driven framework" is that the *pipeline* is boring and reusable, and all the variation — which entity, which columns, which business keys — lives in **data** (rows in SQL tables), not in **code** (ADF JSON). That's what lets one pipeline scale to any number of source files.

---

## 2. Five hops, from raw CSV to a queryable report

Every entity — dimension or fact — makes the same five hops. What differs per entity is *which* file, *which* staging table, and *which* load procedure; the shape of the journey never changes.

```
ADLS Gen2 (raw/<entity>/*.csv)
        │  Copy_ADLS_to_SQL
        ▼
stg schema (raw, typed rows)
        │  Validate + Dedup
        ▼
stg schema (validated + deduplicated)
        │  MERGE / INSERT
        ▼
dw schema (star schema)
        │
        ▼
  reporting views
```

Two Azure resources do the heavy lifting:

| Resource | Role |
|---|---|
| `projectmetadriven` (ADLS Gen2) | Holds the source files, one folder per entity: `raw/orders/`, `raw/product/`, `raw/customer/`, `raw/store/` |
| `sql-employee-data-12345 / metadb` | One database, three schemas: `meta` (control tables), `stg` (staging), `dw` (the star schema and its reporting views) |

---

## 3. The control layer — everything lives in one table

`meta.EntityConfig` is the table the whole framework revolves around. One row per entity. The pipeline reads this row and uses every column as an instruction:

| Column | What it tells the pipeline | Example (`SalesOrder`) |
|---|---|---|
| `EntityType` | Whether to load a dimension or a fact — decides which stored procedure family to call | `Fact` |
| `SourceContainer` / `SourcePathPattern` / `FileName` | Exactly where to find the file in ADLS | `raw` / `orders/` / `SalesOrder.csv` |
| `StagingTable` | Which `stg.*` table receives the raw copy | `SalesOrder` |
| `TargetSchema` / `TargetTable` | Where the cleaned data ultimately lands | `dw.FactSales` |
| `LoadType` | `Full` = wipe staging first; `Incremental` = append and let dedup sort it out | `Incremental` |
| `BusinessKeyColumns` | The natural key(s) dedup partitions on | `OrderId,LineNumber` |
| `WatermarkColumn` | Which column decides which duplicate is "latest" | `OrderDate` |
| `SCDType` | 1 (overwrite) or 2 (version) — only meaningful for dimensions | — |
| `Priority` | Run order, ascending — this is how dimensions load before the fact | `100` (runs last) |

The full row set currently registered:

| Priority | Entity | Type | SCD | Load | Active |
|---:|---|---|:---:|---|:---:|
| 10 | Product | Dimension | 1 | Full | ✓ |
| 20 | Customer | Dimension | 2 | Full | ✓ |
| 30 | Store | Dimension | 1 | Full | ✓ |
| 100 | SalesOrder | Fact | — | Incremental | ✓ |
| 20 | Employee | Dimension | — | Full | ✗ deactivated — out of scope for Sales |

Three more tables round out the control layer: `meta.ColumnMapping` (source column → target column → data type, one row per column, per entity), `meta.ValidationRule` (a business rule as a raw SQL predicate, e.g. `Quantity > 0`), and `meta.SourceSystem` (just registers "SalesERP" as the origin system for lineage).

---

## 4. `PL_MetaDriven_Master` — the orchestrator (2 activities)

The master pipeline has exactly two activities. Its only job is to read the active entities and hand each one to the worker pipeline, in the right order.

```
Lookup_ActiveEntities                 ForEach_Entity (isSequential: true)
 (4 rows, ordered by Priority)  ──▶   Product(10) → Customer(20) → Store(30) → SalesOrder(100)
```

### Activity 1 — `Lookup_ActiveEntities`

Runs one query against `meta.EntityConfig` and returns the result as an array the rest of the pipeline can loop over:

```sql
SELECT
    EntityId, EntityName, EntityType, SourceContainer, SourcePathPattern,
    SourceFileFormat, FileName, StagingTable, TargetSchema, TargetTable,
    LoadType, BusinessKeyColumns, WatermarkColumn
FROM meta.EntityConfig
WHERE IsActive = 1
ORDER BY Priority;
```

Only `IsActive = 1` rows come back — this is exactly why deactivating the old Employee entity (rather than deleting it) was enough to remove it from the run without touching any pipeline logic.

### Activity 2 — `ForEach_Entity`

Iterates the array from the lookup. Two settings decide how it behaves, and both were deliberate fixes:

- **`isSequential: true`** — originally this ran in parallel, with no guaranteed order. Once `FactSales` got real foreign keys to the dimension tables, that became unsafe: the fact load could race ahead of an empty `DimProduct` and fail. Sequential mode plus the `Priority` ordering guarantees dimensions are fully committed before the fact runs.
- For each item, it calls `ExecutePipeline → PL_MetaDriven_ProcessEntity` with `waitOnCompletion: true`, passing `p_EntityId`, `p_EntityName`, `p_EntityType`, and every other column from that row as a pipeline parameter.

---

## 5. `PL_MetaDriven_ProcessEntity` — the generic worker (8 activities)

This is the pipeline that runs once per entity, four times per master run. It never mentions "Product" or "SalesOrder" by name anywhere in its logic — every table name, every stored procedure name, is built at runtime from the parameters the master handed it.

```
Set_StartTime → Script_PrepareLoad → Copy_ADLS_to_SQL → Script_ValidateStaging
     → Script_Dedup → Script_LoadTarget ─┬─▶ (Succeeded) Script_AuditSuccess
                                          └─▶ (Failed)    Script_AuditFailure
```

Every arrow requires the upstream activity to have **Succeeded** — except the two audit activities at the end, which key off **Succeeded** and **Failed** respectively so a run is logged either way.

### Step 1 — `Set_StartTime` (Set Variable)

Stamps a pipeline variable `v_StartTime` with `@utcnow()`. Nothing else in the chain depends on it yet — it exists purely so the two audit activities at the end can report an accurate start time, since ADF doesn't expose "when did this pipeline start" as a built-in expression.

### Step 2 — `Script_PrepareLoad` (Script)

Runs one conditional statement, built as an ADF expression:

```sql
-- when p_LoadType = 'Full'
TRUNCATE TABLE stg.Product;

-- when p_LoadType = 'Incremental'
SELECT 1;
```

Dimensions are configured `Full` — every run replaces the whole staging table, since dimension source files are small snapshots, not deltas. `SalesOrder` is `Incremental`, so staging just keeps accumulating rows across runs, and dedup (step 5) is what keeps that from becoming a mess.

> **Bug fixed here:** the original expression truncated `@{p_StagingTable}` with no schema — SQL Server resolved that against the caller's default schema (`dbo`), not `stg`, and the statement failed with *"Cannot find the object 'Product'"*. This had never been caught because the pipeline had never actually been run before. Fixed by hardcoding the `stg.` prefix into the expression.

### Step 3 — `Copy_ADLS_to_SQL` (Copy Data)

Source and sink are both *parameterized datasets* — `DS_ADLS_DynamicSource` and `DS_SQL_DynamicTarget` — so this one Copy activity works for every entity. The container, folder, filename, and target table are all expressions pointing back at the pipeline's own parameters:

```
source: raw/@{p_SourcePathPattern}@{p_FileName}
sink:   stg.@{p_StagingTable}
```

Two columns get added on the way in that don't exist in the CSV at all: `LoadTimestamp` (`@utcnow()`) and `FileName` (ADF's `$$FILEPATH` token). These are what make dedup and lineage possible later — without a load timestamp, "keep the latest duplicate" has no meaning.

### Step 4 — `Script_ValidateStaging` (Script → `meta.usp_ValidateStagingData`)

Calls a stored procedure with the entity ID and this run's batch ID (the pipeline's own `RunId`). Inside, the procedure reads every active row in `meta.ValidationRule` for this entity and, for each one, runs a dynamic check:

```sql
INSERT INTO stg.ErrorRows (EntityId, BatchId, RowData, ErrorReason, ErrorSeverity)
SELECT @EntityId, @BatchId, (SELECT s.* FOR JSON PATH), @RuleName, @ErrorSeverity
FROM stg.Product AS s
WHERE NOT (ProductId IS NOT NULL);  -- the rule's own expression
```

Nothing here is fatal — rows that fail a rule get logged to `stg.ErrorRows` as JSON, but the pipeline keeps going. That's a deliberate choice: a handful of bad rows shouldn't block the other 999 good ones from loading; you review `ErrorRows` after the fact instead.

### Step 5 — `Script_Dedup` (Script → `meta.usp_DeduplicateStaging`)

This is the one procedure in the whole framework that's *truly* generic — it never mentions a table or column name in its own source code. It reads `BusinessKeyColumns` and `WatermarkColumn` straight out of `EntityConfig` and builds the ranking query as a string:

```sql
;WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY OrderId, LineNumber        -- from BusinessKeyColumns
        ORDER BY OrderDate DESC, LoadTimestamp DESC  -- WatermarkColumn, then tiebreak
    ) AS rn
    FROM stg.SalesOrder
)
-- rank 1 survives; everything else is logged to stg.DuplicateLog, then deleted
```

For `SalesOrder`, that's `OrderId, LineNumber` — an order line is uniquely identified by which order and which line within it. Whichever copy has the newest `OrderDate`, tie-broken by `LoadTimestamp`, is the one that survives.

### Step 6 — `Script_LoadTarget` (Script — dynamic dispatch)

This is the activity that decides *which* load procedure to run, without the pipeline ever hardcoding a procedure name. Its SQL text is itself an ADF expression:

```
@if(
  equals(pipeline().parameters.p_EntityType, 'Dimension'),
  concat('EXEC dw.usp_LoadDim',  pipeline().parameters.p_EntityName, ';'),
  concat('EXEC dw.usp_LoadFact', pipeline().parameters.p_EntityName, ';')
)
```

For the `Product` row, that evaluates to `EXEC dw.usp_LoadDimProduct;`. For `SalesOrder`, it becomes `EXEC dw.usp_LoadFactSalesOrder;`. Naming the fact procedure `usp_LoadFact<EntityName>` (rather than the more obvious `usp_LoadFactSales`, matching the table name) is what makes this convention hold for facts and dimensions alike — the procedure name is always `Load` + short type + entity name.

**Why not one universal load procedure?** Validation and dedup *can* be fully generic because "reject rows that fail an expression" and "keep the newest row per key" don't care what the columns mean. Loading a dimension does — SCD1 overwrites, SCD2 versions with an `EffectiveTo` date, and a fact has to join out to four surrogate keys and compute a measure. That business logic is written once per entity, by hand, as its own procedure — see `SQL_PROCEDURES_REFERENCE.md`.

### Steps 7/8 — `Script_AuditSuccess` / `Script_AuditFailure` (Script → `meta.usp_InsertAuditLog`)

Exactly one of these two runs, decided by ADF's own dependency conditions on the previous activity — `["Succeeded"]` for one, `["Failed"]` for the other. Both call the same logging procedure; the only difference is the `Status` string and, on the failure path, pulling the real error text out of `@activity('Script_LoadTarget').Error.Message`. Every entity, every run, ends up as one row in `meta.ETL_AuditLog` — that table is the answer to "did last night's load work, and if not, why."

---

## 6. The star schema `Script_LoadTarget` is loading into

Four dimensions surround one fact table. The fact never stores a product name or a customer city directly — it stores a small integer *surrogate key* pointing at the dimension row that has that detail, which is what makes the schema fast to query and safe to evolve (a customer's city can change without rewriting every sales row they're on).

```
                 DimDate (5,479 rows, 2018–2032)
                        │  DateKey
                        ▼
DimProduct ──ProductKey──▶  FactSales  ◀──CustomerKey── DimCustomer
 (SCD 1)                (Qty · UnitPrice ·                (SCD 2)
                          NetAmount · CostAmount)
                        ▲
                        │  StoreKey
                    DimStore (SCD 1)
```

All four foreign keys are enforced with real `REFERENCES` constraints — a row can't land in `FactSales` pointing at a dimension key that doesn't exist. Business keys (`ProductId`, `OrderId` …) are kept on their tables too, for lineage back to the source file.

| Table | Rows | Surrogate key | Notes |
|---|---:|---|---|
| DimDate | 5,479 | `DateKey` (YYYYMMDD) | Pre-seeded once, 2018–2032; never touched by the pipeline again |
| DimProduct | 4 | `ProductKey` | SCD1 — attribute changes overwrite in place |
| DimCustomer | 5 | `CustomerKey` | SCD2 — attribute changes create a new version, old one closed |
| DimStore | 3 | `StoreKey` | SCD1, no history tracked |
| FactSales | 8 | `SalesKey` | One row per order line; nonclustered columnstore index for analytics |

---

## 7. Why Customer is treated differently from Product and Store

SCD stands for "slowly changing dimension" — the question is what happens when a source attribute changes between loads.

### SCD Type 1 — Product, Store

When a product's price or category changes, `dw.usp_LoadDimProduct` just `MERGE`s the new value over the old one and stamps `LastUpdated`. No history. This is correct here because nobody needs to know what a product used to cost when analyzing sales — they need the current attribute joined against historical facts.

### SCD Type 2 — Customer

Customer changes are versioned. `dw.usp_LoadDimCustomer` runs two statements: first it closes any current row whose tracked attributes (name, email, city, country, segment) no longer match the incoming staging row — setting `EffectiveTo = now()` and `IsCurrent = 0` — then it inserts the new version as the current row.

```sql
-- close the old version, if attributes changed
UPDATE d SET EffectiveTo = SYSUTCDATETIME(), IsCurrent = 0
FROM dw.DimCustomer d JOIN stg.Customer s ON d.CustomerId = s.CustomerId
WHERE d.IsCurrent = 1 AND (/* any tracked column differs */);

-- insert the new current version (also covers brand-new customers)
INSERT INTO dw.DimCustomer (..., EffectiveFrom, EffectiveTo, IsCurrent, ...)
SELECT ..., SYSUTCDATETIME(), NULL, 1, ...
FROM stg.Customer s WHERE NOT EXISTS (/* an unchanged current row already */);
```

Fact loads always join dimensions on `IsCurrent = 1` (or `IsActive = 1` for SCD1), so a sale is always attributed to whoever the customer was *at load time* — and the closed-off history stays queryable for "what did this customer's profile look like in March" type analysis.

---

## 8. Following one order line from CSV to report

Order `1001`, line `1` — two units of a wireless mouse, sold to Aarav Sharma at the Central Store on August 1st.

1. **In the file** — `raw/orders/SalesOrder.csv` has a row: `1001,1,2026-08-01,P001,C001,S001,2,100.00,10.00,120.00`.
2. **`Copy_ADLS_to_SQL`** lands it in `stg.SalesOrder`, tagging it with the copy's `LoadTimestamp` and source `FileName`.
3. **Validation** checks it against three active rules for this entity — `OrderId IS NOT NULL`, `Quantity > 0`, `UnitPrice >= 0` — all pass, nothing written to `stg.ErrorRows`.
4. **Dedup** partitions by `(OrderId, LineNumber) = (1001, 1)`. If the file had been copied twice (it had, in testing — 56 raw rows collapsed to 8 real order lines), only the newest copy of this row survives; the rest are logged to `stg.DuplicateLog` and deleted.
5. **`Script_LoadTarget`** resolves to `EXEC dw.usp_LoadFactSalesOrder;`, which joins `ProductId = 'P001'` to `DimProduct`, `CustomerId = 'C001'` to `DimCustomer` (`IsCurrent = 1`), `StoreId = 'S001'` to `DimStore`, and the order date to `DimDate.DateKey = 20260801` — then computes `NetAmount = 2 × 100.00 − 10.00 = 190.00` and inserts one row into `FactSales`.
6. **The reporting view** `dw.vw_SalesDetail` joins all four dimensions back in, so a report never has to know a surrogate key exists:

| OrderId | Product | Customer | Store | Qty | NetAmount |
|---|---|---|---|---:|---:|
| 1001 | Wireless Mouse | Aarav Sharma | Central Store | 2 | 190.00 |

---

## 9. Every stored procedure, at a glance

| Procedure | Called from | Generic? | Does |
|---|---|:---:|---|
| `meta.usp_ValidateStagingData` | Script_ValidateStaging | ✓ fully | Runs every active rule for the entity; logs failures, never blocks |
| `meta.usp_DeduplicateStaging` | Script_Dedup | ✓ fully | Ranks rows by business key + watermark; keeps rank 1, logs and deletes the rest |
| `dw.usp_LoadDimProduct` | Script_LoadTarget | per-entity | SCD1 MERGE on `ProductId` |
| `dw.usp_LoadDimCustomer` | Script_LoadTarget | per-entity | SCD2 close-then-insert on `CustomerId` |
| `dw.usp_LoadDimStore` | Script_LoadTarget | per-entity | SCD1 MERGE on `StoreId` |
| `dw.usp_LoadFactSalesOrder` | Script_LoadTarget | per-entity | Joins 4 dims for surrogate keys, computes `NetAmount`, inserts new lines only |
| `meta.usp_InsertAuditLog` | Script_AuditSuccess / Failure | generic (just logs) | One row per entity, per run, into `meta.ETL_AuditLog` |

All four load procedures are wrapped in an explicit `BEGIN TRAN … COMMIT` with a `CATCH` that rolls back and re-throws — a half-applied SCD2 close (old row closed, new row not yet inserted) would otherwise be a real risk if the second statement failed.

---

## 10. Where each piece actually lives

| Thing | Location |
|---|---|
| Source files | `projectmetadriven` storage account, `raw/` container |
| Pipelines & datasets | `adf-employee-data-dev` Data Factory, resource group `RG_DataEngineering` |
| Pipeline source (git) | `azure-adf-employee-project` repo, `main` branch, `/pipeline` folder — this is what ADF Studio's "Validate all" / "Publish" actually read from |
| Control, staging, star schema | `sql-employee-data-12345` server, `metadb` database — schemas `meta` / `stg` / `dw` |
| Run history | `meta.ETL_AuditLog` (per-entity outcome), `stg.ErrorRows` (validation rejects), `stg.DuplicateLog` (dedup rejects) |

> **One thing worth remembering:** ADF Studio, when connected to git, edits and validates against the files in the repo — *not* the live factory directly. A change made through the Azure CLI (or the REST API) updates the live factory but leaves the git copy untouched, so the two can silently drift apart. If Studio ever shows an activity or error that doesn't match what you expect, check the repo's `/pipeline/*.json` first.
