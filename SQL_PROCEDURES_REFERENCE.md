# SQL Stored Procedures Reference

All procedures are in the `metadb` database. They are metadata-driven and designed to be called by ADF pipelines or for manual testing.

---

## Validation Procedures

### `meta.usp_ValidateStagingData`

**Purpose:** Validate staging table rows against metadata-driven rules.

**Signature:**
```sql
EXEC meta.usp_ValidateStagingData @EntityId INT, @BatchId UNIQUEIDENTIFIER;
```

**Parameters:**
- `@EntityId` — Entity to validate (from `meta.EntityConfig.EntityId`)
- `@BatchId` — Batch identifier (typically ADF pipeline RunId)

**How it works:**
1. Reads `meta.EntityConfig` to find the staging table for this entity
2. Reads all active `meta.ValidationRule` rows for this entity
3. For each rule, executes dynamic SQL: `INSERT into stg.ErrorRows WHERE NOT (RuleExpression)`
4. Returns result set with error count

**Returns:**
```
EntityId | BatchId | ErrorCount
---------|---------|----------
1        | <guid>  | 0
```

**Example call (manual):**
```sql
DECLARE @BatchId UNIQUEIDENTIFIER = NEWID();
EXEC meta.usp_ValidateStagingData @EntityId=1, @BatchId=@BatchId;

-- Check errors
SELECT * FROM stg.ErrorRows WHERE BatchId=@BatchId;
```

**ADF call (in Script activity):**
```
EXEC meta.usp_ValidateStagingData
    @EntityId = @EntityId,
    @BatchId = @BatchId;
```

**Notes:**
- Errors are logged to `stg.ErrorRows` (non-fatal); pipeline continues
- Severity (Error|Warning) is stored but not enforced here
- To make this stricter, modify the proc to fail on Error-severity violations

---

## Deduplication Procedures

### `meta.usp_DeduplicateStaging`

**Purpose:** Remove duplicate rows based on business keys; keep latest by watermark.

**Signature:**
```sql
EXEC meta.usp_DeduplicateStaging @EntityId INT;
```

**Parameters:**
- `@EntityId` — Entity to deduplicate (must have `BusinessKeyColumns` defined in `meta.EntityConfig`)

**How it works:**
1. Reads `meta.EntityConfig` to get `BusinessKeyColumns`, `WatermarkColumn`, and staging table name
2. Builds dynamic SQL with `ROW_NUMBER() OVER (PARTITION BY <business keys> ORDER BY <watermark> DESC, LoadTimestamp DESC)`
3. Logs rows with rank > 1 to `stg.DuplicateLog` (for audit)
4. Deletes rank > 1 rows from staging

**Example call (manual):**
```sql
-- Before dedup
SELECT COUNT(*) FROM stg.SalesOrder;  -- Returns 56

EXEC meta.usp_DeduplicateStaging @EntityId=1;

-- After dedup
SELECT COUNT(*) FROM stg.SalesOrder;  -- Returns 8
SELECT COUNT(*) FROM stg.DuplicateLog WHERE EntityName='SalesOrder'; -- Returns 48
```

**Notes:**
- This is truly generic; it works for any entity with business keys
- For SalesOrder (OrderId, LineNumber), it keeps the latest row by OrderDate DESC, then LoadTimestamp DESC
- If `WatermarkColumn` is NULL, it falls back to LoadTimestamp
- Duplicates are logged as JSON in `stg.DuplicateLog` for investigation

**Performance:**
- Uses CTE + ROW_NUMBER (efficient for small-to-medium datasets < 10M rows)
- For huge tables, consider partitioning or using `NOT IN (SELECT...)` instead

---

## Dimension Load Procedures

### `dw.usp_LoadDimProduct`

**Purpose:** Load Product dimension (SCD Type 1 — overwrite).

**Signature:**
```sql
EXEC dw.usp_LoadDimProduct;
```

**No parameters** — reads from `stg.Product` and loads to `dw.DimProduct`

**How it works:**
1. MERGE `dw.DimProduct` tgt using `stg.Product` src on `ProductId`
2. WHEN MATCHED & column changed (ProductName, Category, SubCategory, UnitPrice) → UPDATE attributes + set `LastUpdated = NOW()`
3. WHEN NOT MATCHED → INSERT new row with new `ProductKey` (IDENTITY), `IsActive=1`, `EffectiveFrom=NOW()`
4. Wrapped in transaction; rolls back on error

**Example call:**
```sql
-- Populate stg.Product
INSERT INTO stg.Product (ProductId, ProductName, Category, SubCategory, UnitPrice, LoadTimestamp, FileName)
VALUES ('P005', 'Desk Lamp', 'Office', 'Lighting', 45.00, SYSUTCDATETIME(), 'Product.csv');

-- Load to dimension
EXEC dw.usp_LoadDimProduct;

-- Verify
SELECT * FROM dw.DimProduct WHERE ProductId='P005';
```

**Notes:**
- SCD Type 1 means old values are overwritten; no history is kept
- Only `ProductKey` changes are tracked (history via `LastUpdated`)
- If product becomes inactive, leave it as `IsActive=1`; to deactivate, manually update

---

### `dw.usp_LoadDimCustomer`

**Purpose:** Load Customer dimension (SCD Type 2 — version on change).

**Signature:**
```sql
EXEC dw.usp_LoadDimCustomer;
```

**No parameters** — reads from `stg.Customer` and loads to `dw.DimCustomer`

**How it works:**
1. UPDATE existing current rows (IsCurrent=1) to close them (EffectiveTo=NOW(), IsCurrent=0) if any tracked column changed
   - Tracked columns: CustomerName, Email, City, Country, Segment
2. INSERT new rows (or new versions of changed customers) with IsCurrent=1, EffectiveFrom=NOW(), EffectiveTo=NULL
3. Wrapped in transaction; rolls back on error

**Example call:**
```sql
-- Populate stg.Customer
INSERT INTO stg.Customer (CustomerId, CustomerName, Email, City, Country, Segment, LoadTimestamp, FileName)
VALUES ('C001', 'Aarav Sharma Updated', 'aarav.new@example.com', 'Hyderabad', 'India', 'Premium', SYSUTCDATETIME(), 'Customer.csv');

-- Load to dimension (will close old C001, insert new version)
EXEC dw.usp_LoadDimCustomer;

-- Verify: should have 2 rows for C001 (old closed, new current)
SELECT CustomerId, IsCurrent, EffectiveFrom, EffectiveTo FROM dw.DimCustomer WHERE CustomerId='C001';
```

**Notes:**
- SCD Type 2 keeps full history; each change creates a new version
- Queries must filter `IsCurrent=1` to get the latest customer info
- Use `EffectiveFrom` / `EffectiveTo` for time-travel analysis
- Unique index on `(CustomerId, IsCurrent=1)` prevents duplicates in current version

---

### `dw.usp_LoadDimStore`

**Purpose:** Load Store dimension (SCD Type 1 — overwrite).

**Signature:**
```sql
EXEC dw.usp_LoadDimStore;
```

**No parameters** — reads from `stg.Store` and loads to `dw.DimStore`

**How it works:**
1. MERGE `dw.DimStore` tgt using `stg.Store` src on `StoreId`
2. WHEN MATCHED & column changed → UPDATE attributes
3. WHEN NOT MATCHED → INSERT new row
4. All rows updated have `LastUpdated = NOW()`
5. Wrapped in transaction

**Example call:**
```sql
INSERT INTO stg.Store (StoreId, StoreName, Region, City, LoadTimestamp, FileName)
VALUES ('S004', 'North Store', 'North', 'Delhi', SYSUTCDATETIME(), 'Store.csv');

EXEC dw.usp_LoadDimStore;

SELECT * FROM dw.DimStore WHERE StoreId='S004';
```

---

## Fact Load Procedures

### `dw.usp_LoadFactSalesOrder`

**Purpose:** Load Sales Fact table (incremental, with dimension lookups).

**Signature:**
```sql
EXEC dw.usp_LoadFactSalesOrder;
```

**No parameters** — reads from `stg.SalesOrder` and loads to `dw.FactSales`

**How it works:**
1. Reads from `stg.SalesOrder` (validated and deduplicated)
2. Joins to get surrogate keys:
   - `DimProduct` (business key ProductId, IsActive=1)
   - `DimCustomer` (business key CustomerId, IsCurrent=1)
   - `DimStore` (business key StoreId)
   - `DimDate` (from OrderDate)
3. Calculates `NetAmount = Quantity * UnitPrice - DiscountAmount`
4. Skips rows already in FactSales (on OrderId, LineNumber)
5. Inserts new rows
6. Wrapped in transaction

**Example call:**
```sql
-- Populate stg.SalesOrder
INSERT INTO stg.SalesOrder (OrderId, LineNumber, OrderDate, ProductId, CustomerId, StoreId, Quantity, UnitPrice, DiscountAmount, CostAmount, LoadTimestamp, FileName)
VALUES (1008, 1, '2026-08-08', 'P001', 'C001', 'S001', 2, 100.00, 5.00, 120.00, SYSUTCDATETIME(), 'SalesOrder.csv');

-- Verify dimension data exists
SELECT COUNT(*) FROM dw.DimProduct WHERE ProductId='P001' AND IsActive=1;  -- Must be >= 1
SELECT COUNT(*) FROM dw.DimCustomer WHERE CustomerId='C001' AND IsCurrent=1;  -- Must be >= 1
SELECT COUNT(*) FROM dw.DimStore WHERE StoreId='S001';  -- Must be >= 1

-- Load fact
EXEC dw.usp_LoadFactSalesOrder;

-- Verify
SELECT * FROM dw.FactSales WHERE OrderId=1008;
```

**Output (on success):**
```
SalesKey | DateKey  | ProductKey | CustomerKey | StoreKey | OrderId | LineNumber | Quantity | NetAmount
---------|----------|------------|-------------|----------|---------|------------|----------|----------
9        | 20260808 | 1          | 1           | 1        | 1008    | 1          | 2        | 195.00
```

**Notes:**
- Rows with missing dimension lookups silently skip (INNER JOIN)
  - This is safe because JOINs are on Active/Current flags
  - To debug, look for rows in stg.SalesOrder that don't have matching dim rows
- Incremental load: only new (OrderId, LineNumber) pairs are inserted; duplicates within the same run are skipped
- For re-loads, set LoadType='Full' to truncate staging first

---

## Audit Procedures

### `meta.usp_InsertAuditLog`

**Purpose:** Log pipeline run metadata for observability.

**Signature:**
```sql
EXEC meta.usp_InsertAuditLog
    @BatchId UNIQUEIDENTIFIER,
    @EntityId INT,
    @EntityName VARCHAR(100),
    @LoadType VARCHAR(50),
    @StartTime DATETIME2,
    @EndTime DATETIME2,
    @Status VARCHAR(30),
    @ErrorMessage VARCHAR(2000);
```

**Parameters:**
- `@BatchId` — Batch ID (ADF pipeline RunId)
- `@EntityId` — Entity ID (from EntityConfig)
- `@EntityName` — Entity name (e.g., 'Product', 'SalesOrder')
- `@LoadType` — 'Full' or 'Incremental'
- `@StartTime` — Pipeline start time
- `@EndTime` — Pipeline end time
- `@Status` — 'Success' or 'Failed'
- `@ErrorMessage` — Error text (empty if successful)

**How it works:**
1. Inserts one row into `meta.ETL_AuditLog`
2. No checks; just logs

**Example call (manual):**
```sql
EXEC meta.usp_InsertAuditLog
    @BatchId = '07092f11-a06e-11f1-ba4f-e02e0bc9232b',
    @EntityId = 1,
    @EntityName = 'SalesOrder',
    @LoadType = 'Incremental',
    @StartTime = '2026-08-25 10:13:55.123',
    @EndTime = '2026-08-25 10:15:28.456',
    @Status = 'Success',
    @ErrorMessage = '';

-- Verify
SELECT * FROM meta.ETL_AuditLog WHERE EntityName='SalesOrder' ORDER BY StartTime DESC;
```

**ADF call (in Script activity — success path):**
```
EXEC meta.usp_InsertAuditLog
    @BatchId=@BatchId,
    @EntityId=@EntityId,
    @EntityName=@EntityName,
    @LoadType=@LoadType,
    @StartTime=@StartTime,
    @EndTime=@EndTime,
    @Status=@Status,
    @ErrorMessage=@ErrorMessage;
```

**Notes:**
- Called by ADF after each entity load (both success and failure)
- Use this to track SLA, identify slow runs, drill into errors
- Retention: Keep for at least 90 days for compliance / reprocessing

---

## Utility Queries

### View Run Summary
```sql
SELECT TOP 20 EntityName, LoadType, Status, 
       DATEDIFF(SECOND, StartTime, EndTime) DurationSec,
       StartTime, EndTime
FROM meta.ETL_AuditLog
ORDER BY StartTime DESC;
```

### View Today's Errors
```sql
SELECT TOP 50 EntityName, ErrorReason, COUNT(*) ErrorCount, MAX(CreatedOn) LatestError
FROM stg.ErrorRows
WHERE CAST(CreatedOn AS DATE) = CAST(GETDATE() AS DATE)
GROUP BY EntityName, ErrorReason
ORDER BY ErrorCount DESC;
```

### View Dedup Activity
```sql
SELECT EntityName, COUNT(*) DupCount, MIN(DetectedOn) FirstDup, MAX(DetectedOn) LatestDup
FROM stg.DuplicateLog
WHERE CAST(DetectedOn AS DATE) >= CAST(GETDATE() AS DATE) - 7
GROUP BY EntityName
ORDER BY DupCount DESC;
```

### Restart Staging (Full Load)
```sql
-- If you need to re-run a full load, truncate staging first
TRUNCATE TABLE stg.SalesOrder;
TRUNCATE TABLE stg.ErrorRows;
TRUNCATE TABLE stg.DuplicateLog;

-- Then run the pipeline
```

### Check Dimension Lineage
```sql
-- See all product versions (SCD2 only, if using SCD2)
SELECT * FROM dw.DimCustomer WHERE CustomerId='C001' ORDER BY EffectiveFrom;

-- Or just current
SELECT * FROM dw.DimCustomer WHERE CustomerId='C001' AND IsCurrent=1;
```

### Validate Star Schema Referential Integrity
```sql
-- Check for orphaned facts (missing dimension lookups)
SELECT 'FactSales missing DimDate' AS Issue, COUNT(*) AS Count
FROM dw.FactSales f
WHERE NOT EXISTS (SELECT 1 FROM dw.DimDate d WHERE d.DateKey=f.DateKey)

UNION ALL

SELECT 'FactSales missing DimProduct (Active)', COUNT(*)
FROM dw.FactSales f
WHERE NOT EXISTS (SELECT 1 FROM dw.DimProduct p WHERE p.ProductKey=f.ProductKey AND p.IsActive=1)

UNION ALL

SELECT 'FactSales missing DimCustomer (Current)', COUNT(*)
FROM dw.FactSales f
WHERE NOT EXISTS (SELECT 1 FROM dw.DimCustomer c WHERE c.CustomerKey=f.CustomerKey AND c.IsCurrent=1)

UNION ALL

SELECT 'FactSales missing DimStore', COUNT(*)
FROM dw.FactSales f
WHERE NOT EXISTS (SELECT 1 FROM dw.DimStore s WHERE s.StoreKey=f.StoreKey);
```

---

## Testing Procedures Manually

```sql
-- 1. Populate staging with test data
DELETE FROM stg.SalesOrder;
INSERT INTO stg.SalesOrder (OrderId, LineNumber, OrderDate, ProductId, CustomerId, StoreId, Quantity, UnitPrice, DiscountAmount, CostAmount, LoadTimestamp, FileName)
VALUES 
(1001, 1, '2026-08-01', 'P001', 'C001', 'S001', 2, 100.00, 10.00, 120.00, SYSUTCDATETIME(), 'test.csv'),
(1001, 2, '2026-08-01', 'P002', 'C001', 'S001', 1, 200.00, 20.00, 120.00, SYSUTCDATETIME(), 'test.csv'),
(1001, 2, '2026-08-01', 'P002', 'C001', 'S001', 1, 200.00, 20.00, 120.00, SYSUTCDATETIME(), 'test.csv');  -- Duplicate

-- 2. Run validation
DECLARE @BatchId UNIQUEIDENTIFIER = NEWID();
EXEC meta.usp_ValidateStagingData @EntityId=1, @BatchId=@BatchId;
SELECT * FROM stg.ErrorRows WHERE BatchId=@BatchId;  -- Should be 0 errors if data is good

-- 3. Run dedup
EXEC meta.usp_DeduplicateStaging @EntityId=1;
SELECT COUNT(*) FROM stg.SalesOrder;  -- Should be 2 (1 duplicate removed)
SELECT * FROM stg.DuplicateLog;  -- Should have 1 row

-- 4. Load to fact
EXEC dw.usp_LoadFactSalesOrder;
SELECT COUNT(*) FROM dw.FactSales WHERE OrderDate='2026-08-01';  -- Should be 2

-- 5. Verify in reporting view
SELECT * FROM dw.vw_SalesDetail WHERE OrderId=1001;
```

---

## Summary Table

| Proc | Input | Output | SCD | Metadata-Driven |
|------|-------|--------|-----|-----------------|
| `usp_ValidateStagingData` | stg.* | stg.ErrorRows | — | ✅ (reads ValidationRule) |
| `usp_DeduplicateStaging` | stg.* | stg.DuplicateLog | — | ✅ (reads BusinessKeyColumns) |
| `usp_LoadDimProduct` | stg.Product | dw.DimProduct | 1 | ❌ (hardcoded logic) |
| `usp_LoadDimCustomer` | stg.Customer | dw.DimCustomer | 2 | ❌ (hardcoded logic) |
| `usp_LoadDimStore` | stg.Store | dw.DimStore | 1 | ❌ (hardcoded logic) |
| `usp_LoadFactSalesOrder` | stg.SalesOrder | dw.FactSales | — | ❌ (hardcoded joins) |
| `usp_InsertAuditLog` | params | meta.ETL_AuditLog | — | ❌ (just insert) |

**Note:** Only validation and dedup procs are fully metadata-driven. Dimension and fact load procs are per-entity (one proc per entity). This is intentional — allows custom SCD logic per dim while keeping validation/dedup generic.
