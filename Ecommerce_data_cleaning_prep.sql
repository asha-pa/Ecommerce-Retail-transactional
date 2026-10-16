/*==============================================================================
  SECTION A - SETUP: schema, raw tables, log table, helper objects
==============================================================================*/
SET NOCOUNT ON;
SET LANGUAGE us_english;      -- makes DATENAME(WEEKDAY, ...) return English names
GO

IF SCHEMA_ID('retail') IS NULL EXEC('CREATE SCHEMA retail');
GO

-- Raw landing tables: everything is text, exactly as it arrives from the CSV.
IF OBJECT_ID('retail.raw_2009_2010') IS NULL
    CREATE TABLE retail.raw_2009_2010 (
        Invoice     NVARCHAR(50),  StockCode NVARCHAR(50),  Description NVARCHAR(500),
        Quantity    NVARCHAR(50),  InvoiceDate NVARCHAR(50), Price NVARCHAR(50),
        CustomerID  NVARCHAR(50),  Country NVARCHAR(100));
IF OBJECT_ID('retail.raw_2010_2011') IS NULL
    CREATE TABLE retail.raw_2010_2011 (
        Invoice     NVARCHAR(50),  StockCode NVARCHAR(50),  Description NVARCHAR(500),
        Quantity    NVARCHAR(50),  InvoiceDate NVARCHAR(50), Price NVARCHAR(50),
        CustomerID  NVARCHAR(50),  Country NVARCHAR(100));
GO

-- Issue log: one row per finding / action.
IF OBJECT_ID('retail.issue_log') IS NOT NULL DROP TABLE retail.issue_log;
CREATE TABLE retail.issue_log (
    LogId        INT IDENTITY(1,1) PRIMARY KEY,
    Step         NVARCHAR(30)  NOT NULL,
    Issue        NVARCHAR(300) NOT NULL,
    RowsAffected BIGINT        NULL,
    Action       NVARCHAR(400) NULL,
    LoggedAt     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME());
GO

CREATE OR ALTER PROCEDURE retail.usp_log
    @Step NVARCHAR(30), @Issue NVARCHAR(300), @Rows BIGINT, @Action NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT retail.issue_log (Step, Issue, RowsAffected, Action) VALUES (@Step, @Issue, @Rows, @Action);
    PRINT '[' + @Step + '] ' + @Issue + ': ' + FORMAT(ISNULL(@Rows,0), 'N0') + ' rows -> ' + @Action;
END;
GO

-- Text cleaner: tabs / line breaks / non-breaking spaces -> space, trim, and
-- collapse any run of spaces to ONE space (SQL Server has no regex).
-- Collapse trick: '  ' -> ' ~' ; '~ ' -> '' ; '~' -> ''   (works for any run length)
CREATE OR ALTER FUNCTION retail.fn_clean_text (@s NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    IF @s IS NULL RETURN NULL;
    SET @s = REPLACE(REPLACE(REPLACE(REPLACE(@s, CHAR(9), N' '), CHAR(10), N' '), CHAR(13), N' '), NCHAR(160), N' ');
    SET @s = LTRIM(RTRIM(@s));
    SET @s = REPLACE(REPLACE(REPLACE(@s, N'  ', N' ~'), N'~ ', N''), N'~', N'');
    RETURN NULLIF(@s, N'');
END;
GO

/*
TRUNCATE TABLE retail.raw_2009_2010;
BULK INSERT retail.raw_2009_2010
FROM 'C:\Users\Asha Anandan\Documents\Study Materials\Portfolio Projects\Project 1 E-commerce Customer Intelligence\data_2009_2010.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDQUOTE = '"', CODEPAGE = '65001', TABLOCK);

TRUNCATE TABLE retail.raw_2010_2011;
BULK INSERT retail.raw_2010_2011
FROM 'C:\Users\Asha Anandan\Documents\Study Materials\Portfolio Projects\Project 1 E-commerce Customer Intelligence\data_2010_2011.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDQUOTE = '"', CODEPAGE = '65001', TABLOCK);
*/

-- Select COUNT(*) from [retail].[raw_2009_2010]; Select COUNT(*) from [retail].[raw_2010_2011];

/*==============================================================================
                             DATA CLEANING AND PREPARATION
==============================================================================*/
SET NOCOUNT ON;
SET LANGUAGE us_english;

-- >>> PARAMETER: 1 = remove duplicate lines within a tab, 0 = only flag them

DECLARE @RawRows BIGINT = (SELECT COUNT(*) FROM retail.raw_2009_2010)
                        + (SELECT COUNT(*) FROM retail.raw_2010_2011);
IF @RawRows = 0 THROW 50000, 'Raw tables are empty - load the CSVs first (end of Section A).', 1;

TRUNCATE TABLE retail.issue_log;

/*---------------------------------------------------------------------------
  B1. COMBINE BOTH TABS + SAFE TYPE CONVERSION
  Dates/numbers are converted with TRY_CAST so a bad value becomes NULL (and is
  caught below) instead of aborting the load. CustomerID may arrive as
  '13085' or '13085.0'; going via FLOAT handles both.
---------------------------------------------------------------------------*/
IF OBJECT_ID('retail.stg_combined') IS NOT NULL DROP TABLE retail.stg_combined;
CREATE TABLE retail.stg_combined (
    RowId         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceSheet   NVARCHAR(30)  NOT NULL,
    SheetOrder    TINYINT       NOT NULL,
    SourceRow     INT           NOT NULL,          -- row position in the loaded tab (2 = first data row)
    InvoiceNo     NVARCHAR(50)  NULL,
    StockCode     NVARCHAR(50)  NULL,
    DescriptionRaw NVARCHAR(500) NULL,
    Description   NVARCHAR(500) NULL,
    Quantity      INT           NULL,
    InvoiceDate   DATETIME2(0)  NULL,
    UnitPrice     DECIMAL(18,4) NULL,
    CustomerID    INT           NULL,
    Country       NVARCHAR(100) NULL,
    CountryOriginal NVARCHAR(100) NULL,
    InvoiceType   VARCHAR(12)   NULL,              -- Sale / Cancellation / Adjustment
    LineCategory  VARCHAR(20)   NULL,
    IsStandardStockCode BIT     NULL,
    IsProduct     BIT           NULL,
    CustomerCountry NVARCHAR(100) NULL,
    CustomerHasMultipleCountries BIT NOT NULL DEFAULT 0,
    InvoiceDay    DATE          NULL,
    [Year]        SMALLINT      NULL,
    [Month]       TINYINT       NULL,
    YearMonth     CHAR(7)       NULL,
    [Weekday]     VARCHAR(10)   NULL,
    [Hour]        TINYINT       NULL,
    HasCustomerID BIT           NULL,
    LineTotal     DECIMAL(18,2) NULL,
    IsReturn      BIT           NULL,
    IsDuplicate   BIT           NOT NULL DEFAULT 0,
    PriceOutlier  BIT           NOT NULL DEFAULT 0,
    QuantityOutlier BIT         NOT NULL DEFAULT 0,
    LineValueOutlier BIT        NOT NULL DEFAULT 0,
    IsSameDayReversal BIT       NOT NULL DEFAULT 0,
    ExclusionReason NVARCHAR(200) NULL);          -- NULL = row stays in the clean table

INSERT INTO retail.stg_combined
    (SourceSheet, SheetOrder, SourceRow, InvoiceNo, StockCode, DescriptionRaw, Quantity,
     InvoiceDate, UnitPrice, CustomerID, Country)
SELECT  r.SourceSheet, r.SheetOrder, r.SourceRow,
        NULLIF(r.Invoice, N''), NULLIF(r.StockCode, N''), NULLIF(r.Description, N''),
        TRY_CAST(TRY_CAST(NULLIF(LTRIM(RTRIM(r.Quantity)), N'') AS DECIMAL(18,4)) AS INT),
        TRY_CAST(NULLIF(LTRIM(RTRIM(r.InvoiceDate)), N'') AS DATETIME2(0)),
        TRY_CAST(TRY_CAST(NULLIF(LTRIM(RTRIM(r.Price)), N'') AS FLOAT) AS DECIMAL(18,4)),
        TRY_CAST(TRY_CAST(NULLIF(LTRIM(RTRIM(r.CustomerID)), N'') AS FLOAT) AS INT),
        NULLIF(r.Country, N'')
FROM (
    SELECT N'Year 2009-2010' AS SourceSheet, CAST(1 AS TINYINT) AS SheetOrder,
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) + 1 AS SourceRow,
           Invoice, StockCode, Description, Quantity, InvoiceDate, Price, CustomerID, Country
    FROM retail.raw_2009_2010
    UNION ALL
    SELECT N'Year 2010-2011', CAST(2 AS TINYINT),
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) + 1,
           Invoice, StockCode, Description, Quantity, InvoiceDate, Price, CustomerID, Country
    FROM retail.raw_2010_2011
) r
ORDER BY r.SheetOrder, r.SourceRow;


DECLARE @n BIGINT;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'1 Load', N'Rows loaded from both tabs', @n, N'Combined into retail.stg_combined';

SELECT @n = COUNT(*) FROM retail.stg_combined
WHERE Quantity IS NULL OR InvoiceDate IS NULL OR UnitPrice IS NULL OR InvoiceNo IS NULL OR StockCode IS NULL;
EXEC retail.usp_log N'1 Load', N'Rows with unparseable / missing Quantity, Date, Price, Invoice or StockCode', @n,
     N'Excluded in step 9 if any (expected 0)';

/*---------------------------------------------------------------------------
  B2. SCHEMA: raw names (Invoice / Price / Customer ID) were mapped to the
  data-dictionary names (InvoiceNo / UnitPrice / CustomerID) in the load above.
---------------------------------------------------------------------------*/
EXEC retail.usp_log N'2 Schema', N'Column names differ from data dictionary (Invoice/Price/Customer ID)', 0,
     N'Renamed to InvoiceNo / UnitPrice / CustomerID';

/*---------------------------------------------------------------------------
  B3. TEXT HYGIENE: trim, collapse repeated spaces, upper-case codes/descriptions
---------------------------------------------------------------------------*/

SELECT @n = COUNT(*) FROM retail.stg_combined WHERE StockCode IS NOT NULL
  AND DATALENGTH(StockCode) <> DATALENGTH(retail.fn_clean_text(StockCode));
EXEC retail.usp_log N'3 Text', N'StockCode: leading/trailing/double whitespace', @n, N'Trimmed and collapsed';

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE StockCode IS NOT NULL
  AND StockCode COLLATE Latin1_General_BIN2 <> UPPER(StockCode) COLLATE Latin1_General_BIN2;
EXEC retail.usp_log N'3 Text', N'StockCode mixed case (e.g. 15056bl / 15056BL)', @n, N'Upper-cased';

UPDATE retail.stg_combined
SET InvoiceNo   = retail.fn_clean_text(InvoiceNo),
    StockCode   = UPPER(retail.fn_clean_text(StockCode)),
    Description = UPPER(retail.fn_clean_text(DescriptionRaw)),
    Country     = retail.fn_clean_text(Country);

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined
WHERE DescriptionRaw IS NOT NULL AND DATALENGTH(DescriptionRaw) <> DATALENGTH(Description);
EXEC retail.usp_log N'3 Text', N'Description: leading/trailing/double whitespace', @n,
     N'Trimmed and collapsed to single spaces; upper-cased (raw kept in DescriptionRaw)';

SELECT * FROM [retail].[stg_combined]

/*---------------------------------------------------------------------------
  B4. TYPES: CustomerID float ('13085.0') -> INT (done in load)
---------------------------------------------------------------------------*/
DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE CustomerID IS NOT NULL;
EXEC retail.usp_log N'4 Types', N'CustomerID arrives as float because of missing values', @n,
     N'Converted to INT (NULL kept for missing)';

/*---------------------------------------------------------------------------
  B5. INVOICE VALIDATION + CLASSIFICATION
  Dictionary: 6 digits, 'C' prefix = cancellation. Reality: also an 'A'
  prefix (bad-debt accounting adjustments).
---------------------------------------------------------------------------*/
UPDATE retail.stg_combined
SET InvoiceType = CASE WHEN InvoiceNo LIKE 'C%' THEN 'Cancellation'
                       WHEN InvoiceNo LIKE 'A%' THEN 'Adjustment'
                       ELSE 'Sale' END;

SELECT @n = COUNT(*) FROM retail.stg_combined
WHERE InvoiceNo IS NOT NULL
  AND NOT (InvoiceNo LIKE '[0-9][0-9][0-9][0-9][0-9][0-9]'
        OR InvoiceNo LIKE '[CA][0-9][0-9][0-9][0-9][0-9][0-9]');
EXEC retail.usp_log N'5 Invoice', N'InvoiceNo not matching [C|A]+6 digits', @n, N'None expected';

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE InvoiceType = 'Cancellation';
EXEC retail.usp_log N'5 Invoice', N'Cancellation invoices (C prefix)', @n, N'InvoiceType = Cancellation';
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE InvoiceType = 'Adjustment';
EXEC retail.usp_log N'5 Invoice', N'Undocumented A-prefix invoices (bad-debt adjustments)', @n,
     N'InvoiceType = Adjustment (excluded in step 9)';

/*---------------------------------------------------------------------------
  B6. OVERLAP BETWEEN TABS (1-9 Dec 2010 is in both)
  First PROVE the two copies are identical (multiset compare, both directions),
  then drop the Tab-2 copy.
---------------------------------------------------------------------------*/
SELECT DISTINCT a.InvoiceNo INTO #shared
FROM retail.stg_combined a
JOIN retail.stg_combined b ON a.InvoiceNo = b.InvoiceNo AND a.SheetOrder = 1 AND b.SheetOrder = 2;

SELECT InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country, COUNT(*) AS c
INTO #ov1 FROM retail.stg_combined
WHERE SheetOrder = 1 AND InvoiceNo IN (SELECT InvoiceNo FROM #shared)
GROUP BY InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country;

SELECT InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country, COUNT(*) AS c
INTO #ov2 FROM retail.stg_combined
WHERE SheetOrder = 2 AND InvoiceNo IN (SELECT InvoiceNo FROM #shared)
GROUP BY InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country;

IF EXISTS (SELECT * FROM #ov1 EXCEPT SELECT * FROM #ov2)
OR EXISTS (SELECT * FROM #ov2 EXCEPT SELECT * FROM #ov1)
    THROW 50001, 'Overlapping invoices differ between the two tabs - investigate before dropping.', 1;


DECLARE @n BIGINT;
UPDATE retail.stg_combined
SET ExclusionReason = N'Cross-tab duplicate (1-9 Dec 2010 present in both tabs)'
WHERE SheetOrder = 2 AND InvoiceNo IN (SELECT InvoiceNo FROM #shared) AND ExclusionReason IS NULL;
SET @n = @@ROWCOUNT;
DECLARE @SharedInv INT = (SELECT COUNT(*) FROM #shared);
DECLARE @msg NVARCHAR(300) = FORMAT(@SharedInv, 'N0') + N' invoices present in both tabs (copies verified identical)';
EXEC retail.usp_log N'6 Overlap', @msg, @n, N'Kept the Tab-1 copy, excluded the Tab-2 copy';
DROP TABLE #shared, #ov1, #ov2;

/*---------------------------------------------------------------------------
  B7. DUPLICATE LINES WITHIN A TAB
  Same invoice + item + qty + price + customer + country. Description and
  timestamp are NOT in the key (both are tidied later and would hide dups).
  First occurrence is kept. Set @DropDuplicates = 0 to flag only.
---------------------------------------------------------------------------*/
SELECT RowId INTO #dups
FROM (SELECT RowId,
             ROW_NUMBER() OVER (PARTITION BY InvoiceNo, StockCode, Quantity, UnitPrice, CustomerID, Country
                                ORDER BY SheetOrder, SourceRow) AS rn
      FROM retail.stg_combined WHERE ExclusionReason IS NULL) d
WHERE rn > 1;

DECLARE @n BIGINT;
DECLARE @DropDuplicates BIT = 1;
UPDATE s
SET IsDuplicate = 1,
    ExclusionReason = CASE WHEN @DropDuplicates = 1
        THEN N'Duplicate line (same invoice, item, quantity, price, customer, country)' END
FROM retail.stg_combined s JOIN #dups d ON d.RowId = s.RowId;

SET @n = @@ROWCOUNT;
DECLARE @act NVARCHAR(400) = CASE WHEN @DropDuplicates = 1
                                  THEN N'Kept first occurrence, excluded the rest'
                                  ELSE N'Flagged only (IsDuplicate)' END;
EXEC retail.usp_log N'7 Duplicates', N'Duplicate lines within a tab (same invoice/item/qty/price)', @n, @act;
DROP TABLE #dups;

/*---------------------------------------------------------------------------
  B8. LINE CLASSIFICATION: product vs postage / fee / voucher / test
  Dictionary says StockCode = 5-digit number. Reality: letter suffixes
  (85123A) plus service codes (POST, DOT, M, D, BANK CHARGES, gift_0001_20 ...)
---------------------------------------------------------------------------*/
UPDATE retail.stg_combined
SET LineCategory = CASE
        WHEN StockCode IN ('POST','DOT','C2','C3')                              THEN 'Postage/Carriage'
        WHEN StockCode = 'D'                                                    THEN 'Discount'
        WHEN StockCode = 'M'                                                    THEN 'Manual'
        WHEN StockCode = 'S'                                                    THEN 'Sample'
        WHEN StockCode IN ('BANK CHARGES','AMAZONFEE','ADJUST','ADJUST2','CRUK','B') THEN 'Fee/Adjustment'
        WHEN StockCode IN ('TEST001','TEST002')                                 THEN 'Test'
        WHEN StockCode LIKE 'GIFT[_]%'                                          THEN 'Gift Voucher'
        ELSE 'Product' END,
    IsStandardStockCode = CASE WHEN StockCode LIKE '[0-9][0-9][0-9][0-9][0-9]'
                                 OR StockCode LIKE '[0-9][0-9][0-9][0-9][0-9][A-Z]'
                                 OR StockCode LIKE '[0-9][0-9][0-9][0-9][0-9][A-Z][A-Z]'
                               THEN 1 ELSE 0 END;
UPDATE retail.stg_combined SET IsProduct = CASE WHEN LineCategory = 'Product' THEN 1 ELSE 0 END;

--SELECT * FROM [retail].[stg_combined]

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE ExclusionReason IS NULL AND IsStandardStockCode = 0;
EXEC retail.usp_log N'8 Classify', N'Non-standard StockCodes (not 5 digits + optional letters)', @n,
     N'Kept; classified in LineCategory (or left as Product, e.g. DCGS gift sets)';
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE ExclusionReason IS NULL AND IsProduct = 0;
EXEC retail.usp_log N'8 Classify', N'Non-product lines (LineCategory <> Product)', @n, N'Flagged with IsProduct / LineCategory';

/*---------------------------------------------------------------------------
  B9. INVALID / NON-SALE ROWS -> excluded (applied in this order, each step
  only looks at rows still in play, exactly like the Python pipeline)
---------------------------------------------------------------------------*/
DECLARE @n BIGINT;
UPDATE retail.stg_combined SET ExclusionReason = N'Unparseable or missing Quantity, Date, Price, Invoice or StockCode'
WHERE ExclusionReason IS NULL
  AND (Quantity IS NULL OR InvoiceDate IS NULL OR UnitPrice IS NULL OR InvoiceNo IS NULL OR StockCode IS NULL);
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'Unparseable / missing key fields', @n, N'Excluded';

UPDATE retail.stg_combined SET ExclusionReason = N'Test product (TEST001/TEST002)'
WHERE ExclusionReason IS NULL AND LineCategory = 'Test';
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'Test records', @n, N'Excluded';

UPDATE retail.stg_combined SET ExclusionReason = N'Negative unit price (bad-debt accounting adjustment)'
WHERE ExclusionReason IS NULL AND UnitPrice < 0;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'Negative UnitPrice', @n, N'Excluded';

UPDATE retail.stg_combined SET ExclusionReason = N'''A'' invoice - accounting adjustment, not a sale'
WHERE ExclusionReason IS NULL AND InvoiceType = 'Adjustment';
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'Remaining A invoices (positive-price legs of bad-debt adjustments)', @n, N'Excluded';

-- Zero price: ~99% have no customer, ~70% no description, mostly negative qty on
-- non-C invoices ("damaged", "check", "thrown away") = stock write-offs, not sales.
UPDATE retail.stg_combined SET ExclusionReason = N'Zero unit price (stock adjustment / write-off / free item)'
WHERE ExclusionReason IS NULL AND UnitPrice = 0;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'UnitPrice = 0', @n, N'Excluded';

UPDATE retail.stg_combined SET ExclusionReason = N'Negative quantity on non-cancellation invoice'
WHERE ExclusionReason IS NULL AND Quantity < 0 AND InvoiceType <> 'Cancellation';
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'Negative Quantity without C prefix (after zero-price removal)', @n, N'Excluded';

UPDATE retail.stg_combined SET ExclusionReason = N'Cancellation invoice with positive quantity'
WHERE ExclusionReason IS NULL AND InvoiceType = 'Cancellation' AND Quantity > 0;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'9 Exclude', N'C invoice with positive Quantity', @n, N'Excluded';

/*---------------------------------------------------------------------------
  B10. DESCRIPTION STANDARDISATION
  One StockCode has many names (renames over time, typos, free-text notes such
  as '?' or 'WRONGLY MARKED CARTON 22804'). Master name = most frequent
  description among valid priced lines (ties: alphabetical).
---------------------------------------------------------------------------*/
SELECT StockCode, Description, COUNT(*) AS n
INTO #desc_counts
FROM retail.stg_combined
WHERE ExclusionReason IS NULL AND Description IS NOT NULL AND UnitPrice > 0
GROUP BY StockCode, Description;

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM (SELECT StockCode FROM #desc_counts GROUP BY StockCode HAVING COUNT(*) > 1) x;
EXEC retail.usp_log N'10 Description', N'StockCodes with >1 description variant (after trim/upper-case)', @n,
     N'Master name = most frequent description';

SELECT StockCode, Description AS MasterDescription
INTO #master
FROM (SELECT StockCode, Description,
             ROW_NUMBER() OVER (PARTITION BY StockCode ORDER BY n DESC, Description) AS rn
      FROM #desc_counts) x
WHERE rn = 1;

SELECT @n = COUNT(*) FROM retail.stg_combined s JOIN #master m ON m.StockCode = s.StockCode
WHERE s.ExclusionReason IS NULL AND s.Description IS NOT NULL
  AND s.Description COLLATE Latin1_General_BIN2 <> m.MasterDescription COLLATE Latin1_General_BIN2;
EXEC retail.usp_log N'10 Description', N'Description replaced by master name', @n, N'Standardised';

SELECT @n = COUNT(*) FROM retail.stg_combined s JOIN #master m ON m.StockCode = s.StockCode
WHERE s.ExclusionReason IS NULL AND s.Description IS NULL;
EXEC retail.usp_log N'10 Description', N'Missing Description filled from master (by StockCode)', @n, N'Imputed';

UPDATE s SET Description = m.MasterDescription
FROM retail.stg_combined s JOIN #master m ON m.StockCode = s.StockCode
WHERE s.ExclusionReason IS NULL;

UPDATE retail.stg_combined SET ExclusionReason = N'Missing description and no master name for StockCode'
WHERE ExclusionReason IS NULL AND Description IS NULL;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'10 Description', N'Still missing after fill', @n, N'Excluded';
DROP TABLE #desc_counts, #master;

/*---------------------------------------------------------------------------
  B11. COUNTRY
---------------------------------------------------------------------------*/
UPDATE retail.stg_combined
SET CountryOriginal = Country,
    Country = CASE Country WHEN 'EIRE' THEN 'Ireland' WHEN 'RSA' THEN 'South Africa'
                           WHEN 'USA' THEN 'United States' WHEN 'Korea' THEN 'South Korea'
                           WHEN 'Unspecified' THEN 'Unknown' WHEN 'European Community' THEN 'Unknown'
                           ELSE Country END;

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM retail.stg_combined
WHERE ExclusionReason IS NULL AND Country COLLATE Latin1_General_BIN2 <> CountryOriginal COLLATE Latin1_General_BIN2;
EXEC retail.usp_log N'11 Country', N'Non-standard names (EIRE, RSA, USA, Korea, Unspecified, European Community)', @n,
     N'Mapped; Unspecified/European Community -> Unknown (original in CountryOriginal)';

-- Customers seen under more than one country: keep transaction country, add most-frequent country + flag
SELECT CustomerID, Country AS CustomerCountry, CAST(CASE WHEN nCountries > 1 THEN 1 ELSE 0 END AS BIT) AS Multi
INTO #cust_country
FROM (SELECT CustomerID, Country,
             ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY n DESC, Country) AS rn,
             COUNT(*) OVER (PARTITION BY CustomerID) AS nCountries
      FROM (SELECT CustomerID, Country, COUNT(*) AS n
            FROM retail.stg_combined
            WHERE ExclusionReason IS NULL AND CustomerID IS NOT NULL
            GROUP BY CustomerID, Country) c) r
WHERE rn = 1;

UPDATE s SET CustomerCountry = c.CustomerCountry, CustomerHasMultipleCountries = c.Multi
FROM retail.stg_combined s JOIN #cust_country c ON c.CustomerID = s.CustomerID
WHERE s.ExclusionReason IS NULL;
SELECT @n = COUNT(*) FROM #cust_country WHERE Multi = 1;
EXEC retail.usp_log N'11 Country', N'Customers linked to >1 country', @n,
     N'Kept transaction Country; added CustomerCountry (most frequent) + flag';
DROP TABLE #cust_country;

/*---------------------------------------------------------------------------
  B12. DATES: one timestamp per invoice + derived time fields
---------------------------------------------------------------------------*/
SELECT InvoiceNo, MIN(InvoiceDate) AS MinTs, COUNT(DISTINCT InvoiceDate) AS nTs
INTO #inv_ts FROM retail.stg_combined WHERE ExclusionReason IS NULL GROUP BY InvoiceNo;

DECLARE @n BIGINT;
SELECT @n = COUNT(*) FROM #inv_ts WHERE nTs > 1;
EXEC retail.usp_log N'12 Date', N'Invoices whose lines carry different timestamps (1-9 min apart)', @n,
     N'Set every line to the invoice''s first timestamp';

UPDATE s SET InvoiceDate = t.MinTs
FROM retail.stg_combined s JOIN #inv_ts t ON t.InvoiceNo = s.InvoiceNo
WHERE s.ExclusionReason IS NULL AND s.InvoiceDate <> t.MinTs;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'12 Date', N'Lines whose timestamp was changed', @n, N'Harmonised to invoice timestamp';
DROP TABLE #inv_ts;

UPDATE retail.stg_combined
SET InvoiceDay = CAST(InvoiceDate AS DATE),
    [Year]     = YEAR(InvoiceDate),
    [Month]    = MONTH(InvoiceDate),
    YearMonth  = CONVERT(CHAR(7), InvoiceDate, 120),
    [Weekday]  = DATENAME(WEEKDAY, InvoiceDate),
    [Hour]     = DATEPART(HOUR, InvoiceDate)
WHERE ExclusionReason IS NULL;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'12 Date', N'Derived InvoiceDay/Year/Month/YearMonth/Weekday/Hour', @n, N'Added';
-- Observations (not errors): Dec 2011 is incomplete (data ends 9 Dec 2011);
-- Saturday trading appears only on 5 Dec 2009.

/*---------------------------------------------------------------------------
  B13. MISSING CustomerID: not imputed, flagged
---------------------------------------------------------------------------*/
DECLARE @n BIGINT;
UPDATE retail.stg_combined SET HasCustomerID = CASE WHEN CustomerID IS NULL THEN 0 ELSE 1 END;
SELECT @n = COUNT(*) FROM retail.stg_combined WHERE ExclusionReason IS NULL AND HasCustomerID = 0;
EXEC retail.usp_log N'13 Customer', N'Missing CustomerID', @n,
     N'NOT imputed. Filter HasCustomerID = 1 for customer analytics';

/*---------------------------------------------------------------------------
  B14. MEASURES
---------------------------------------------------------------------------*/
UPDATE retail.stg_combined
SET LineTotal = CAST(ROUND(Quantity * UnitPrice, 2) AS DECIMAL(18,2)),
    IsReturn  = CASE WHEN Quantity < 0 THEN 1 ELSE 0 END
WHERE ExclusionReason IS NULL;
DECLARE @n BIGINT;
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'14 Measures', N'LineTotal = Quantity x UnitPrice (negative for cancellations); IsReturn', @n, N'Added';

/*---------------------------------------------------------------------------
  B15. OUTLIER FLAGS (flag only - nothing is deleted)
---------------------------------------------------------------------------*/
-- Price vs the StockCode median (codes with at least 5 lines)
DECLARE @n BIGINT;
DECLARE @msg NVARCHAR(300)
;WITH p AS (
    SELECT RowId, UnitPrice,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY UnitPrice) OVER (PARTITION BY StockCode) AS med,
           COUNT(*) OVER (PARTITION BY StockCode) AS cnt
    FROM retail.stg_combined WHERE ExclusionReason IS NULL AND IsProduct = 1)
UPDATE s SET PriceOutlier = 1
FROM retail.stg_combined s JOIN p ON p.RowId = s.RowId
WHERE p.cnt >= 5 AND (p.UnitPrice > 10 * p.med OR p.UnitPrice < 0.1 * p.med);
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'15 Outliers', N'Unit price >10x or <0.1x the StockCode median (codes with >=5 lines)', @n,
     N'Flagged PriceOutlier';

-- Quantity and line value above the 99.9th percentile of product lines
DECLARE @qThr FLOAT, @vThr FLOAT;
;WITH a AS (SELECT ABS(CAST(Quantity AS FLOAT)) AS q FROM retail.stg_combined
            WHERE ExclusionReason IS NULL AND IsProduct = 1)
SELECT TOP (1) @qThr = PERCENTILE_CONT(0.999) WITHIN GROUP (ORDER BY q) OVER () FROM a;
;WITH a AS (SELECT ABS(CAST(LineTotal AS FLOAT)) AS v FROM retail.stg_combined
            WHERE ExclusionReason IS NULL AND IsProduct = 1)
SELECT TOP (1) @vThr = PERCENTILE_CONT(0.999) WITHIN GROUP (ORDER BY v) OVER () FROM a;


UPDATE retail.stg_combined SET QuantityOutlier = 1
WHERE ExclusionReason IS NULL AND IsProduct = 1 AND ABS(CAST(Quantity AS FLOAT)) > @qThr;
SET @n = @@ROWCOUNT;
SET @msg = N'|Quantity| > P99.9 (' + FORMAT(@qThr, 'N0') + N')';
EXEC retail.usp_log N'15 Outliers', @msg, @n, N'Flagged QuantityOutlier';

UPDATE retail.stg_combined SET LineValueOutlier = 1
WHERE ExclusionReason IS NULL AND IsProduct = 1 AND ABS(CAST(LineTotal AS FLOAT)) > @vThr;
SET @n = @@ROWCOUNT;
SET @msg = N'|LineTotal| > P99.9 (GBP ' + FORMAT(@vThr, 'N0') + N')';
EXEC retail.usp_log N'15 Outliers', @msg, @n, N'Flagged LineValueOutlier';

-- Cancellation that fully reverses a sale (same customer, item, quantity) within 24h
CREATE INDEX IX_stg_rev ON retail.stg_combined (CustomerID, StockCode, Quantity) INCLUDE (InvoiceDate, ExclusionReason);
UPDATE c SET IsSameDayReversal = 1
FROM retail.stg_combined c
WHERE c.ExclusionReason IS NULL AND c.Quantity < 0 AND c.CustomerID IS NOT NULL
  AND EXISTS (SELECT 1 FROM retail.stg_combined s
              WHERE s.ExclusionReason IS NULL AND s.Quantity = -c.Quantity
                AND s.CustomerID = c.CustomerID AND s.StockCode = c.StockCode
                AND s.InvoiceDate <= c.InvoiceDate
                AND s.InvoiceDate >= DATEADD(DAY, -1, c.InvoiceDate));
SET @n = @@ROWCOUNT;
EXEC retail.usp_log N'15 Outliers', N'Cancellation fully reversing a sale within 24h', @n,
     N'Flagged IsSameDayReversal (consider excluding from volume KPIs)';

/*---------------------------------------------------------------------------
  B16. SPLIT: clean fact table  vs  excluded audit table
---------------------------------------------------------------------------*/

IF OBJECT_ID('retail.fact_transactions') IS NOT NULL DROP TABLE retail.fact_transactions;
CREATE TABLE retail.fact_transactions (
    LineId       BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    InvoiceNo    NVARCHAR(50)  NOT NULL, InvoiceType VARCHAR(12) NOT NULL,
    InvoiceDate  DATETIME2(0)  NOT NULL, InvoiceDay DATE NOT NULL,
    [Year] SMALLINT NOT NULL, [Month] TINYINT NOT NULL, YearMonth CHAR(7) NOT NULL,
    [Weekday] VARCHAR(10) NOT NULL, [Hour] TINYINT NOT NULL,
    StockCode    NVARCHAR(50)  NOT NULL, Description NVARCHAR(500) NOT NULL,
    LineCategory VARCHAR(20)   NOT NULL, IsProduct BIT NOT NULL,
    Quantity     INT           NOT NULL, UnitPrice DECIMAL(18,4) NOT NULL, LineTotal DECIMAL(18,2) NOT NULL,
    IsReturn     BIT           NOT NULL,
    CustomerID   INT           NULL,     HasCustomerID BIT NOT NULL,
    Country      NVARCHAR(100) NULL,     CountryOriginal NVARCHAR(100) NULL,
    CustomerCountry NVARCHAR(100) NULL,  CustomerHasMultipleCountries BIT NOT NULL,
    PriceOutlier BIT NOT NULL, QuantityOutlier BIT NOT NULL, LineValueOutlier BIT NOT NULL,
    IsSameDayReversal BIT NOT NULL,
    SourceSheet  NVARCHAR(30)  NOT NULL, SourceRow INT NOT NULL);

INSERT INTO retail.fact_transactions
    (InvoiceNo, InvoiceType, InvoiceDate, InvoiceDay, [Year], [Month], YearMonth, [Weekday], [Hour],
     StockCode, Description, LineCategory, IsProduct, Quantity, UnitPrice, LineTotal, IsReturn,
     CustomerID, HasCustomerID, Country, CountryOriginal, CustomerCountry, CustomerHasMultipleCountries,
     PriceOutlier, QuantityOutlier, LineValueOutlier, IsSameDayReversal, SourceSheet, SourceRow)
SELECT InvoiceNo, InvoiceType, InvoiceDate, InvoiceDay, [Year], [Month], YearMonth, [Weekday], [Hour],
       StockCode, Description, LineCategory, IsProduct, Quantity, UnitPrice, LineTotal, IsReturn,
       CustomerID, HasCustomerID, Country, CountryOriginal, CustomerCountry, CustomerHasMultipleCountries,
       PriceOutlier, QuantityOutlier, LineValueOutlier, IsSameDayReversal, SourceSheet, SourceRow
FROM retail.stg_combined
WHERE ExclusionReason IS NULL
ORDER BY InvoiceDate, InvoiceNo, StockCode;

CREATE INDEX IX_fact_customer ON retail.fact_transactions (CustomerID, InvoiceDate) INCLUDE (InvoiceNo, LineTotal, Quantity, IsProduct);
CREATE INDEX IX_fact_month    ON retail.fact_transactions (YearMonth) INCLUDE (LineTotal, IsProduct, Country);

IF OBJECT_ID('retail.excluded_rows') IS NOT NULL DROP TABLE retail.excluded_rows;
SELECT InvoiceNo, StockCode, Description, DescriptionRaw, Quantity, InvoiceDate, UnitPrice,
       CustomerID, Country, SourceSheet, SourceRow, ExclusionReason
INTO retail.excluded_rows
FROM retail.stg_combined
WHERE ExclusionReason IS NOT NULL;

/*---------------------------------------------------------------------------
  B17. RECONCILIATION + VALIDATION (the script stops with an error if it fails)
---------------------------------------------------------------------------*/
DECLARE @n BIGINT;
DECLARE @msg NVARCHAR(300)
DECLARE @RawRows BIGINT
DECLARE @DropDuplicates BIT = 1;
DECLARE @fact BIGINT = (SELECT COUNT(*) FROM retail.fact_transactions);
DECLARE @excl BIGINT = (SELECT COUNT(*) FROM retail.excluded_rows);
IF @RawRows <> @fact + @excl THROW 50002, 'Row reconciliation failed: raw <> clean + excluded.', 1;
SET @msg = N'Raw ' + FORMAT(@RawRows,'N0') + N' = clean ' + FORMAT(@fact,'N0') + N' + excluded ' + FORMAT(@excl,'N0');
EXEC retail.usp_log N'17 Reconcile', @msg, @RawRows, N'Reconciled';

IF EXISTS (SELECT 1 FROM retail.fact_transactions WHERE UnitPrice <= 0)
    THROW 50003, 'Validation failed: non-positive UnitPrice in clean table.', 1;
IF EXISTS (SELECT 1 FROM retail.fact_transactions WHERE Description IS NULL OR LTRIM(RTRIM(Description)) = '')
    THROW 50004, 'Validation failed: missing Description in clean table.', 1;
IF EXISTS (SELECT 1 FROM retail.fact_transactions WHERE (InvoiceType = 'Cancellation' AND Quantity >= 0) OR (InvoiceType <> 'Cancellation' AND Quantity < 0))
    THROW 50005, 'Validation failed: cancellation flag disagrees with sign of Quantity.', 1;
IF @DropDuplicates = 1 AND EXISTS (
        SELECT 1 FROM retail.fact_transactions
        GROUP BY InvoiceNo, StockCode, Quantity, UnitPrice, CustomerID, Country HAVING COUNT(*) > 1)
    THROW 50006, 'Validation failed: duplicate lines remain in clean table.', 1;
IF EXISTS (SELECT 1 FROM retail.fact_transactions GROUP BY StockCode HAVING COUNT(DISTINCT Description) > 1)
    THROW 50007, 'Validation failed: a StockCode has more than one Description.', 1;
PRINT 'All post-clean validation checks passed';

/*---------------------------------------------------------------------------
  B18. DIMENSION TABLES
---------------------------------------------------------------------------*/
IF OBJECT_ID('retail.dim_product') IS NOT NULL DROP TABLE retail.dim_product;
;WITH med AS (
    SELECT DISTINCT StockCode,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY UnitPrice) OVER (PARTITION BY StockCode) AS MedianUnitPrice
    FROM retail.fact_transactions)
SELECT f.StockCode, MAX(f.Description) AS Description, MIN(f.LineCategory) AS LineCategory,
       CAST(MAX(m.MedianUnitPrice) AS DECIMAL(18,4)) AS MedianUnitPrice,
       MIN(f.UnitPrice) AS MinUnitPrice, MAX(f.UnitPrice) AS MaxUnitPrice,
       MIN(f.InvoiceDate) AS FirstSold, MAX(f.InvoiceDate) AS LastSold, COUNT(*) AS LineCount
INTO retail.dim_product
FROM retail.fact_transactions f JOIN med m ON m.StockCode = f.StockCode
GROUP BY f.StockCode;
ALTER TABLE retail.dim_product ALTER COLUMN StockCode NVARCHAR(50) NOT NULL;
ALTER TABLE retail.dim_product ADD CONSTRAINT PK_dim_product PRIMARY KEY (StockCode);

IF OBJECT_ID('retail.dim_customer') IS NOT NULL DROP TABLE retail.dim_customer;
SELECT CustomerID, MAX(CustomerCountry) AS Country,
       MIN(InvoiceDate) AS FirstPurchase, MAX(InvoiceDate) AS LastPurchase,
       COUNT(DISTINCT InvoiceNo) AS Invoices, SUM(LineTotal) AS NetRevenue
INTO retail.dim_customer
FROM retail.fact_transactions WHERE CustomerID IS NOT NULL
GROUP BY CustomerID;
ALTER TABLE retail.dim_customer ALTER COLUMN CustomerID INT NOT NULL;
ALTER TABLE retail.dim_customer ADD CONSTRAINT PK_dim_customer PRIMARY KEY (CustomerID);

-- Summaries to look at
SELECT ExclusionReason, COUNT(*) AS Rows FROM retail.excluded_rows GROUP BY ExclusionReason ORDER BY Rows DESC;
SELECT * FROM retail.issue_log ORDER BY LogId;
GO


/*==============================================================================
  SECTION C - RFM SEGMENTATION
  Population : lines with a CustomerID, product items only, Quantity > 0
               (returns, postage, fees, vouchers are not "purchases")
  Snapshot   : the day after the last transaction, so Recency is never 0
  Scores     : 1-5 by quintile (5 = best). Quintile edges use PERCENTILE_CONT
               (linear interpolation) with "value <= edge" bins, which is the
               same rule as pandas qcut. Frequency has many ties, so - as in the
               Python version - customers are ranked (Frequency, CustomerID)
               and the ranks are cut into quintiles.
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Snapshot DATE;
SELECT @Snapshot = DATEADD(DAY, 1, CAST(MAX(InvoiceDate) AS DATE))
FROM retail.fact_transactions WHERE HasCustomerID = 1 AND IsProduct = 1 AND Quantity > 0;

IF OBJECT_ID('tempdb..#rfm_base') IS NOT NULL DROP TABLE #rfm_base;
SELECT CustomerID,
       MAX(InvoiceDate)                                           AS LastPurchase,
       DATEDIFF(DAY, CAST(MAX(InvoiceDate) AS DATE), @Snapshot)   AS Recency,
       COUNT(DISTINCT InvoiceNo)                                  AS Frequency,
       SUM(LineTotal)                                             AS Monetary
INTO #rfm_base
FROM retail.fact_transactions
WHERE HasCustomerID = 1 AND IsProduct = 1 AND Quantity > 0
GROUP BY CustomerID;

IF OBJECT_ID('tempdb..#edges') IS NOT NULL DROP TABLE #edges;
SELECT DISTINCT
       R1 = PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY Recency)  OVER (),
       R2 = PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY Recency)  OVER (),
       R3 = PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY Recency)  OVER (),
       R4 = PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY Recency)  OVER (),
       M1 = PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY Monetary) OVER (),
       M2 = PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY Monetary) OVER (),
       M3 = PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY Monetary) OVER (),
       M4 = PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY Monetary) OVER (),
       N  = CAST(COUNT(*) OVER () AS FLOAT)
INTO #edges
FROM #rfm_base;

IF OBJECT_ID('retail.rfm_customers') IS NOT NULL DROP TABLE retail.rfm_customers;
;WITH ranked AS (
    -- Frequency rank: ties broken by CustomerID (same as pandas rank(method='first'))
    SELECT CustomerID, LastPurchase, Recency, Frequency, Monetary,
           ROW_NUMBER() OVER (ORDER BY Frequency, CustomerID) AS FRank
    FROM #rfm_base),
scored AS (
    SELECT b.CustomerID, b.LastPurchase, b.Recency, b.Frequency, b.Monetary,
           CASE WHEN b.Recency <= e.R1 THEN 5 WHEN b.Recency <= e.R2 THEN 4
                WHEN b.Recency <= e.R3 THEN 3 WHEN b.Recency <= e.R4 THEN 2 ELSE 1 END AS R,
           CASE WHEN b.FRank <= 1 + (e.N - 1) * 0.2 THEN 1 WHEN b.FRank <= 1 + (e.N - 1) * 0.4 THEN 2
                WHEN b.FRank <= 1 + (e.N - 1) * 0.6 THEN 3 WHEN b.FRank <= 1 + (e.N - 1) * 0.8 THEN 4 ELSE 5 END AS F,
           CASE WHEN b.Monetary <= e.M1 THEN 1 WHEN b.Monetary <= e.M2 THEN 2
                WHEN b.Monetary <= e.M3 THEN 3 WHEN b.Monetary <= e.M4 THEN 4 ELSE 5 END AS M
    FROM ranked b CROSS JOIN #edges e)
SELECT CustomerID, LastPurchase, Recency, Frequency, Monetary, R, F, M,
       CAST(R AS CHAR(1)) + CAST(F AS CHAR(1)) + CAST(M AS CHAR(1)) AS RFM_Score,
       CAST(CASE
            WHEN R >= 4 AND F >= 4 THEN 'Champions'
            WHEN R >= 3 AND F >= 4 THEN 'Loyal Customers'
            WHEN R >= 4 AND F = 3  THEN 'Potential Loyalists'
            WHEN R = 5  AND F <= 2 THEN 'New Customers'
            WHEN R >= 3 AND F <= 3 THEN 'Promising / Need Attention'
            WHEN R <= 2 AND F >= 4 THEN 'Can''t Lose Them'
            WHEN R <= 2 AND F = 3  THEN 'At Risk'
            WHEN R <= 2 AND F = 2  THEN 'About to Sleep'
            ELSE 'Lost' END AS VARCHAR(30)) AS Segment
INTO retail.rfm_customers
FROM scored;
ALTER TABLE retail.rfm_customers ALTER COLUMN CustomerID INT NOT NULL;
ALTER TABLE retail.rfm_customers ADD CONSTRAINT PK_rfm_customers PRIMARY KEY (CustomerID);

IF OBJECT_ID('retail.rfm_segment_summary') IS NOT NULL DROP TABLE retail.rfm_segment_summary;
SELECT Segment,
       COUNT(*)                                         AS Customers,
       CAST(AVG(CAST(Recency   AS FLOAT)) AS DECIMAL(10,1)) AS AvgRecencyDays,
       CAST(AVG(CAST(Frequency AS FLOAT)) AS DECIMAL(10,1)) AS AvgFrequency,
       CAST(AVG(Monetary) AS DECIMAL(12,1))             AS AvgMonetary,
       SUM(Monetary)                                    AS TotalRevenue,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()          AS DECIMAL(5,1)) AS PctCustomers,
       CAST(100.0 * SUM(Monetary) / SUM(SUM(Monetary)) OVER () AS DECIMAL(5,1)) AS PctRevenue
INTO retail.rfm_segment_summary
FROM retail.rfm_customers
GROUP BY Segment;

SELECT * FROM retail.rfm_segment_summary ORDER BY TotalRevenue DESC;

-- Example drill-down: who are the high-value customers we are about to lose?
SELECT TOP (20) CustomerID, Recency, Frequency, Monetary, RFM_Score
FROM retail.rfm_customers WHERE Segment = 'Can''t Lose Them' ORDER BY Monetary DESC;
GO


/*==============================================================================
  SECTION D - COHORT RETENTION
  Cohort    : month of the customer's FIRST purchase
  Activity  : a month in which the customer placed at least one invoice
  Retention : % of the cohort active N months after the cohort month
  Same population as RFM (CustomerID present, products, Quantity > 0).
  Months that lie beyond the end of the data are left out (not shown as 0%).
==============================================================================*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#cust_months') IS NOT NULL DROP TABLE #cust_months;
SELECT DISTINCT CustomerID, DATEFROMPARTS(YEAR(InvoiceDate), MONTH(InvoiceDate), 1) AS OrderMonth
INTO #cust_months
FROM retail.fact_transactions
WHERE HasCustomerID = 1 AND IsProduct = 1 AND Quantity > 0;
--SELECT * FROM #cust_months

IF OBJECT_ID('tempdb..#cust_cohort') IS NOT NULL DROP TABLE #cust_cohort;
SELECT CustomerID, MIN(OrderMonth) AS CohortMonth INTO #cust_cohort FROM #cust_months GROUP BY CustomerID;

IF OBJECT_ID('tempdb..#activity') IS NOT NULL DROP TABLE #activity;
SELECT c.CohortMonth, DATEDIFF(MONTH, c.CohortMonth, m.OrderMonth) AS MonthIndex,
       COUNT(DISTINCT m.CustomerID) AS ActiveCustomers
INTO #activity
FROM #cust_months m JOIN #cust_cohort c ON c.CustomerID = m.CustomerID
GROUP BY c.CohortMonth, DATEDIFF(MONTH, c.CohortMonth, m.OrderMonth);

DECLARE @LastMonth DATE = (SELECT MAX(OrderMonth) FROM #cust_months);
DECLARE @MaxIdx INT = DATEDIFF(MONTH, (SELECT MIN(CohortMonth) FROM #cust_cohort), @LastMonth);

IF OBJECT_ID('retail.cohort_retention') IS NOT NULL DROP TABLE retail.cohort_retention;
;WITH idx AS (
        SELECT 0 AS MonthIndex
        UNION ALL SELECT MonthIndex + 1 FROM idx WHERE MonthIndex < @MaxIdx),
     sizes AS (SELECT CohortMonth, COUNT(*) AS CohortSize FROM #cust_cohort GROUP BY CohortMonth)
SELECT s.CohortMonth, i.MonthIndex, s.CohortSize,
       ISNULL(a.ActiveCustomers, 0) AS ActiveCustomers,
       CAST(100.0 * ISNULL(a.ActiveCustomers, 0) / s.CohortSize AS DECIMAL(5,1)) AS RetentionPct
INTO retail.cohort_retention
FROM sizes s
CROSS JOIN idx i
LEFT JOIN #activity a ON a.CohortMonth = s.CohortMonth AND a.MonthIndex = i.MonthIndex
WHERE i.MonthIndex <= DATEDIFF(MONTH, s.CohortMonth, @LastMonth)     -- only months that exist in the data
OPTION (MAXRECURSION 1000);

-- Result 1: retention % matrix (rows = cohort, columns = months since first purchase)
DECLARE @cols NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @cols = STRING_AGG(CAST(QUOTENAME(CAST(MonthIndex AS NVARCHAR(10))) AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY MonthIndex)
FROM (SELECT DISTINCT MonthIndex FROM retail.cohort_retention) x;

SET @sql = N'SELECT CONVERT(CHAR(7), CohortMonth, 120) AS CohortMonth, CohortSize, ' + @cols + N'
FROM (SELECT CohortMonth, CohortSize, MonthIndex, RetentionPct FROM retail.cohort_retention) s
PIVOT (MAX(RetentionPct) FOR MonthIndex IN (' + @cols + N')) p
ORDER BY CohortMonth;';
EXEC sys.sp_executesql @sql;

-- Result 2: same matrix as customer counts
SET @sql = N'SELECT CONVERT(CHAR(7), CohortMonth, 120) AS CohortMonth, CohortSize, ' + @cols + N'
FROM (SELECT CohortMonth, CohortSize, MonthIndex, ActiveCustomers FROM retail.cohort_retention) s
PIVOT (MAX(ActiveCustomers) FOR MonthIndex IN (' + @cols + N')) p
ORDER BY CohortMonth;';
EXEC sys.sp_executesql @sql;

-- Result 3: average retention curve across cohorts
SELECT MonthIndex, CAST(AVG(RetentionPct) AS DECIMAL(5,1)) AS AvgRetentionPct, COUNT(*) AS CohortsIncluded
FROM retail.cohort_retention WHERE MonthIndex > 0 GROUP BY MonthIndex ORDER BY MonthIndex;
GO


/*==============================================================================
  SECTION E - PARITY CHECK AGAINST THE PYTHON PIPELINE
  Python results on the same file (with @DropDuplicates = 1). Small differences
  (a few rows) can appear from collation / decimal-vs-float handling; a large
  gap means something in the load is different - check the CSV export.
==============================================================================*/
SET NOCOUNT ON;

;WITH expected (Metric, PythonValue) AS (
    SELECT 'Raw rows loaded',                    1067371 UNION ALL
    SELECT 'Cross-tab duplicate rows excluded',    22523 UNION ALL
    SELECT 'Duplicate lines excluded',             11816 UNION ALL
    SELECT 'Zero-price rows excluded',              6011 UNION ALL
    SELECT 'Clean rows',                         1026997 UNION ALL
    SELECT 'Excluded rows',                        40374 UNION ALL
    SELECT 'Distinct invoices (clean)',            48353 UNION ALL
    SELECT 'Distinct customers (clean)',            5939 UNION ALL
    SELECT 'Distinct stock codes (clean)',          4757 UNION ALL
    SELECT 'Net revenue GBP (all clean lines)',  19001985 UNION ALL
    SELECT 'RFM customers',                         5852 UNION ALL
    SELECT 'RFM Champions',                         1469 UNION ALL
    SELECT 'Cohort 2009-12 size',                    951),
actual (Metric, SqlValue) AS (
    SELECT 'Raw rows loaded', (SELECT COUNT(*) FROM retail.raw_2009_2010) + (SELECT COUNT(*) FROM retail.raw_2010_2011) UNION ALL
    SELECT 'Cross-tab duplicate rows excluded', (SELECT COUNT(*) FROM retail.excluded_rows WHERE ExclusionReason LIKE 'Cross-tab%') UNION ALL
    SELECT 'Duplicate lines excluded',          (SELECT COUNT(*) FROM retail.excluded_rows WHERE ExclusionReason LIKE 'Duplicate line%') UNION ALL
    SELECT 'Zero-price rows excluded',          (SELECT COUNT(*) FROM retail.excluded_rows WHERE ExclusionReason LIKE 'Zero unit price%') UNION ALL
    SELECT 'Clean rows',                        (SELECT COUNT(*) FROM retail.fact_transactions) UNION ALL
    SELECT 'Excluded rows',                     (SELECT COUNT(*) FROM retail.excluded_rows) UNION ALL
    SELECT 'Distinct invoices (clean)',         (SELECT COUNT(DISTINCT InvoiceNo) FROM retail.fact_transactions) UNION ALL
    SELECT 'Distinct customers (clean)',        (SELECT COUNT(DISTINCT CustomerID) FROM retail.fact_transactions) UNION ALL
    SELECT 'Distinct stock codes (clean)',      (SELECT COUNT(DISTINCT StockCode) FROM retail.fact_transactions) UNION ALL
    SELECT 'Net revenue GBP (all clean lines)', (SELECT CAST(ROUND(SUM(LineTotal), 0) AS BIGINT) FROM retail.fact_transactions) UNION ALL
    SELECT 'RFM customers',                     (SELECT COUNT(*) FROM retail.rfm_customers) UNION ALL
    SELECT 'RFM Champions',                     (SELECT COUNT(*) FROM retail.rfm_customers WHERE Segment = 'Champions') UNION ALL
    SELECT 'Cohort 2009-12 size',               (SELECT MAX(CohortSize) FROM retail.cohort_retention WHERE CohortMonth = '2009-12-01'))
SELECT e.Metric, e.PythonValue, a.SqlValue, a.SqlValue - e.PythonValue AS Diff,
       CASE WHEN a.SqlValue = e.PythonValue THEN 'MATCH'
            WHEN ABS(a.SqlValue - e.PythonValue) <= 0.001 * e.PythonValue THEN 'CLOSE (<0.1%)'
            ELSE 'CHECK' END AS Result
FROM expected e JOIN actual a ON a.Metric = e.Metric;
GO
