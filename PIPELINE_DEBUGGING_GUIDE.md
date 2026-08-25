# ADF Pipeline Debugging Guide

## Overview

This guide provides step-by-step instructions to debug and troubleshoot the Metadata-Driven Sales ETL framework when things go wrong.

---

## Quick Diagnosis Checklist

When a pipeline fails, run through this in order:

1. **Check ADF Pipeline Run Status**
   ```powershell
   az datafactory pipeline-run show --factory-name adf-employee-data-dev \
     -g RG_DataEngineering --run-id <runId> -o json
   ```
   - Look at the `message` field for the top-level error
   - Look at `status` field (InProgress|Succeeded|Failed)

2. **Check which activity failed**
   ```powershell
   az datafactory activity-run query --factory-name adf-employee-data-dev \
     -g RG_DataEngineering --last-updated-after 2026-08-20T00:00:00 \
     --last-updated-before 2026-08-26T00:00:00 -o json | jq '.value[] | {activity: .activityName, status: .status, failureType: .failureType}'
   ```

3. **Check SQL logs for row-level errors**
   ```sql
   -- Validation rejects
   SELECT TOP 20 EntityId, ErrorReason, RowData, CreatedOn 
   FROM stg.ErrorRows 
   ORDER BY CreatedOn DESC;
   
   -- Dedup logs
   SELECT TOP 20 EntityName, RowData, DetectedOn 
   FROM stg.DuplicateLog 
   ORDER BY DetectedOn DESC;
   
   -- Run audit
   SELECT TOP 20 * 
   FROM meta.ETL_AuditLog 
   ORDER BY StartTime DESC;
   ```

4. **If still unclear, re-run in Debug mode** (ADF Studio)
   - Publish changes, go to ADF Pipeline editor
   - Set breakpoints on activities
   - Click "Debug" and inspect variable values / output

---

## Scenario-Based Troubleshooting

### Scenario 1: "Operation on target Script_PrepareLoad failed: Cannot find object 'Product'…"

**Symptom:** Pipeline fails at the truncate step before copy.

**Root Cause:** Schema prefix missing in dynamic SQL, or staging table doesn't exist.

**Diagnosis:**
```sql
-- Check if staging tables exist
SELECT TABLE_SCHEMA, TABLE_NAME 
FROM INFORMATION_SCHEMA.TABLES 
WHERE TABLE_NAME IN ('Product', 'Customer', 'Store', 'SalesOrder');

-- Expected: 4 rows, all in 'stg' schema
```

**Fix:**

If tables don't exist, create them:
```sql
CREATE TABLE stg.Product (
    ProductId     NVARCHAR(50)  NOT NULL,
    ProductName   NVARCHAR(200) NULL,
    Category      NVARCHAR(100) NULL,
    SubCategory   NVARCHAR(100) NULL,
    UnitPrice     DECIMAL(18,4) NULL,
    LoadTimestamp DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    FileName      NVARCHAR(500) NULL
);
```

If the issue is the dynamic SQL (Schema prefix), review the ADF activity `Script_PrepareLoad`:
- The text value should be: `@if(equals(pipeline().parameters.p_LoadType,'Full'),concat('TRUNCATE TABLE stg.',pipeline().parameters.p_StagingTable,';'),'SELECT 1;')`
- Note the `'stg.'` prefix before `@{...}`

---

### Scenario 2: "Copy_ADLS_to_SQL fails: Authentication failed / Access denied"

**Root Cause:** ADLS firewall rule missing, or linked service credentials invalid.

**Diagnosis:**
```powershell
# Check linked service (LS_ADLS_DataLake)
az datafactory linked-service show \
  --factory-name adf-employee-data-dev \
  -g RG_DataEngineering \
  --name LS_ADLS_DataLake -o json

# Verify the URL is correct
# Expected: https://projectmetadriven.dfs.core.windows.net/

# Try to list containers
az storage container list --account-name projectmetadriven --auth-mode key
```

**Fix:**

If ADLS linked service auth fails:
- Verify account key in Key Vault (ADF linked services use encrypted credentials)
- Or switch to Managed Identity (easier, no secrets to manage)
  ```powershell
  # Grant ADF's Managed Identity access to ADLS
  az role assignment create \
    --assignee <adf-msi-object-id> \
    --role "Storage Blob Data Contributor" \
    --scope /subscriptions/430ac7c6-e735-4991-b100-76d94f7abdeb/resourceGroups/RG_DataEngineering/providers/Microsoft.Storage/storageAccounts/projectmetadriven
  ```

---

### Scenario 3: "Script_ValidateStaging fails: Column 'xxx' does not exist…"

**Root Cause:** Schema mismatch between CSV file and staging table definition.

**Diagnosis:**
```sql
-- Check expected columns for SalesOrder
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE 
FROM INFORMATION_SCHEMA.COLUMNS 
WHERE TABLE_SCHEMA='stg' AND TABLE_NAME='SalesOrder' 
ORDER BY ORDINAL_POSITION;

-- Expected: OrderId, LineNumber, OrderDate, ProductId, CustomerId, StoreId, 
--          Quantity, UnitPrice, DiscountAmount, CostAmount, LoadTimestamp, FileName

-- Check CSV header in ADLS
az storage blob download --account-name projectmetadriven --container-name raw \
  --name orders/SalesOrder.csv --auth-mode key --file ~/temp/sales.csv
head -1 ~/temp/sales.csv
```

**Fix:** Ensure CSV columns match table columns exactly (case-sensitive in some databases). If columns are missing or extra:
- Update staging table definition
- OR update CSV file format

---

### Scenario 4: "Script_Dedup runs but stg.DuplicateLog is empty; stg.SalesOrder still has duplicates"

**Root Cause:** `BusinessKeyColumns` not defined in `meta.EntityConfig`, or dedup proc has a bug.

**Diagnosis:**
```sql
-- Check EntityConfig
SELECT EntityId, EntityName, BusinessKeyColumns, WatermarkColumn 
FROM meta.EntityConfig 
WHERE EntityName='SalesOrder';

-- Expected: BusinessKeyColumns='OrderId,LineNumber', WatermarkColumn='OrderDate'

-- Manually run dedup to see error
EXEC meta.usp_DeduplicateStaging @EntityId=1;

-- Check if ErrorRows table has errors
SELECT TOP 20 ErrorReason, RowData 
FROM stg.ErrorRows 
WHERE EntityId=1 
ORDER BY CreatedOn DESC;
```

**Fix:**

If `BusinessKeyColumns` is NULL or wrong:
```sql
UPDATE meta.EntityConfig 
SET BusinessKeyColumns='OrderId,LineNumber', 
    WatermarkColumn='OrderDate' 
WHERE EntityName='SalesOrder';
```

If dedup proc is throwing SQL error, check the dynamic SQL generation. The proc reads metadata and builds:
```sql
ROW_NUMBER() OVER (
  PARTITION BY OrderId, LineNumber
  ORDER BY OrderDate DESC, LoadTimestamp DESC
) AS rn
```

If your business keys have spaces or special characters, they must be quoted in the proc (use `QUOTENAME()`).

---

### Scenario 5: "FactSales loads 0 rows; stg.SalesOrder has data"

**Root Cause:** Dimension lookup failure (orphaned foreign key) or fact proc error.

**Diagnosis:**
```sql
-- Check dimension row counts
SELECT COUNT(*) AS DimProduct FROM dw.DimProduct WHERE IsActive=1;
SELECT COUNT(*) AS DimCustomer FROM dw.DimCustomer WHERE IsCurrent=1;
SELECT COUNT(*) AS DimStore FROM dw.DimStore;
SELECT COUNT(*) AS DimDate FROM dw.DimDate;

-- Find rows in staging that can't be joined to dims
SELECT s.* 
FROM stg.SalesOrder s
LEFT JOIN dw.DimProduct p ON p.ProductId=s.ProductId AND p.IsActive=1
LEFT JOIN dw.DimCustomer c ON c.CustomerId=s.CustomerId AND c.IsCurrent=1
LEFT JOIN dw.DimStore st ON st.StoreId=s.StoreId
LEFT JOIN dw.DimDate d ON CONVERT(INT, CONVERT(VARCHAR(8), s.OrderDate, 112)) = d.DateKey
WHERE p.ProductKey IS NULL OR c.CustomerKey IS NULL OR st.StoreKey IS NULL OR d.DateKey IS NULL;

-- Try to load manually and see error
EXEC dw.usp_LoadFactSalesOrder;

-- If there are errors, they may be silent (INNER JOIN means missing dims skip rows)
-- To see them, modify the proc to use LEFT JOIN + error logging
```

**Fix:**

1. Ensure all dimensions are loaded first:
   ```sql
   -- In meta.EntityConfig, check Priority
   SELECT EntityId, EntityName, Priority FROM meta.EntityConfig ORDER BY Priority;
   ```
   Dimensions must have Priority < Fact.

2. Ensure dimension CSVs exist in ADLS:
   ```powershell
   az storage blob list --account-name projectmetadriven --container-name raw --auth-mode key
   # Look for: product/Product.csv, customer/Customer.csv, store/Store.csv
   ```

3. If dimensions are missing, upload them (see "Uploading Test Data" section below).

4. Or, check if dim load procs have errors:
   ```sql
   -- Run dim load manually
   EXEC dw.usp_LoadDimProduct;
   -- Then check row count
   SELECT COUNT(*) FROM dw.DimProduct;
   ```

---

### Scenario 6: "Pipeline runs successfully but row counts are very low"

**Root Cause:** Validation rules are too strict; most rows are being rejected.

**Diagnosis:**
```sql
-- Check error counts
SELECT TOP 20 ErrorReason, COUNT(*) AS ErrorCount 
FROM stg.ErrorRows 
GROUP BY ErrorReason 
ORDER BY ErrorCount DESC;

-- Look for patterns (e.g., all UnitPrice > 0 failures)
SELECT TOP 100 ErrorReason, RowData 
FROM stg.ErrorRows 
WHERE EntityId=1 
ORDER BY CreatedOn DESC;
```

**Fix:**

1. Review the rules:
   ```sql
   SELECT RuleName, RuleExpression, ErrorSeverity 
   FROM meta.ValidationRule 
   WHERE EntityId=1 AND IsActive=1;
   ```

2. If rule is too strict, either:
   - Disable it: `UPDATE meta.ValidationRule SET IsActive=0 WHERE RuleName='...';`
   - Downgrade severity: `UPDATE meta.ValidationRule SET ErrorSeverity='Warning' WHERE RuleName='...';`
   - Fix source data (contact data owner)

3. Or, check if the rule expression is wrong:
   - `UnitPrice > 0` means negative prices are rejected (good)
   - `ISNULL(UnitPrice, 0) > 0` means NULL prices are rejected (stricter)

---

## Uploading Test Data

To re-test the pipeline with fresh data:

```powershell
# Create sample CSV
$product = @"
ProductId,ProductName,Category,SubCategory,UnitPrice
P001,Wireless Mouse,Electronics,Accessories,100.00
P002,Mechanical Keyboard,Electronics,Accessories,200.00
"@

$product | Out-File -FilePath ~/product.csv -Encoding UTF8

# Upload to ADLS
az storage blob upload \
  --account-name projectmetadriven \
  --container-name raw \
  --name product/Product.csv \
  --file ~/product.csv \
  --auth-mode key \
  --overwrite

# Verify
az storage blob list --account-name projectmetadriven --container-name raw --auth-mode key
```

---

## Manual Pipeline Run for Testing

To trigger the pipeline and monitor in real-time:

```powershell
# Trigger
$run = az datafactory pipeline create-run \
  --factory-name adf-employee-data-dev \
  -g RG_DataEngineering \
  --name PL_MetaDriven_Master -o json | ConvertFrom-Json

$runId = $run.runId
Write-Output "Run ID: $runId"

# Poll status
for ($i=0; $i -lt 60; $i++) {
  $status = az datafactory pipeline-run show \
    --factory-name adf-employee-data-dev \
    -g RG_DataEngineering \
    --run-id $runId -o json | ConvertFrom-Json
  
  Write-Output "Status: $($status.status)"
  
  if ($status.status -in @("Succeeded", "Failed", "Cancelled")) {
    Write-Output "Message: $($status.message)"
    break
  }
  
  Start-Sleep -Seconds 10
}

# See activity details
az datafactory activity-run query \
  --factory-name adf-employee-data-dev \
  -g RG_DataEngineering \
  --filter-parameters RunId eq '$runId' -o json
```

---

## SQL Connection Troubleshooting

If you can't connect to `metadb` to run diagnostic queries:

```powershell
# Test connectivity
Test-NetConnection -ComputerName sql-employee-data-12345.database.windows.net -Port 1433

# Try sqlcmd with Azure AD
sqlcmd -S sql-employee-data-12345.database.windows.net -d metadb -G

# Or via PowerShell (Invoke-SqlCmd)
# Requires: Import-Module SqlServer
$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
Invoke-SqlCmd -ServerInstance "sql-employee-data-12345.database.windows.net" `
              -Database "metadb" `
              -AccessToken $token `
              -Query "SELECT 1"
```

---

## Performance Tuning

If the pipeline is slow:

1. **Copy step is slow (Copy_ADLS_to_SQL):**
   - Increase Parallel Copies in the Copy activity (default 1; can go up to 32)
   - Partition source data (organize CSVs by date; copy processes them in parallel)

2. **Validation/Dedup steps are slow:**
   - Add indexes on `stg.SalesOrder(OrderId, LineNumber)` for dedup lookup
   - Add indexes on `meta.ValidationRule(EntityId, IsActive)` for validation lookup

3. **Fact load is slow:**
   - Add index on `dw.DimProduct(ProductId, IsActive)` for fast joins
   - Add index on `dw.DimCustomer(CustomerId, IsCurrent)` for fast joins
   - Consider batch inserts if row count is huge (current proc does single EXEC; could switch to CTAS + partition switch for millions of rows)

```sql
-- Create indexes
CREATE INDEX IX_SalesOrder_BizKey ON stg.SalesOrder(OrderId, LineNumber);
CREATE INDEX IX_DimProduct_BizKey ON dw.DimProduct(ProductId) WHERE IsActive=1;
CREATE INDEX IX_DimCustomer_BizKey ON dw.DimCustomer(CustomerId) WHERE IsCurrent=1;
CREATE INDEX IX_DimStore_BizKey ON dw.DimStore(StoreId);
```

---

## Common Error Messages & Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `Incorrect syntax near 'SELECT'` | Malformed SQL in ADF expression | Check quotes, semicolons, escape characters |
| `Invalid column name 'xxx'` | Staging table schema mismatch | Verify table definition matches CSV |
| `Login failed for user '<token>'` | AAD auth not configured | Ensure AAD admin is set on SQL server |
| `The remote name could not be resolved` | DNS/network issue | Check firewall rules, linked service URL |
| `Timeout error [258]` | Connection timeout | Increase timeout in ADF; check firewall |
| `Cannot insert duplicate key` | FK violation or unique constraint | Check dimension existence; verify business keys |

---

## Enabling ADF Debug Mode

For interactive debugging:

1. Go to Azure Portal → Data Factories → adf-employee-data-dev
2. Click "Author" (pencil icon)
3. Open pipeline `PL_MetaDriven_Master` or `PL_MetaDriven_ProcessEntity`
4. Click "Debug" button (top)
5. ADF will run the pipeline in debug mode
6. Click activities to see their inputs/outputs in real-time
7. Hover over variables to see their values
8. Errors will show inline

---

## Conclusion

Use this guide in combination with the logs (`meta.ETL_AuditLog`, `stg.ErrorRows`, `stg.DuplicateLog`) and ADF Portal activity runs to diagnose 95% of issues. When in doubt, re-run the failing entity with detailed logging enabled, or contact your DBA for deeper SQL investigation.
