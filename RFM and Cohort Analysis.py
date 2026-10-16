#!/usr/bin/env python
# coding: utf-8

# In[3]:


""" RFM segmentation + Cohort retention on the cleaned Online Retail II table.
Input : fact_transactions_clean.csv.gz  (output of online_retail_cleaning_pipeline.py)
Output: rfm_customers.csv, rfm_segment_summary.csv, cohort_retention_pct.csv,
        cohort_retention_counts.csv, cohort_retention_heatmap.png
"""


# In[4]:


import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# In[5]:


OUTPUT_RFM = "C:/Users/Asha Anandan/Documents/Study Materials/Portfolio Projects/Project 1 E-commerce Customer Intelligence/Outputs/Output_RFM/"
OUTPUT_COHORT = "C:/Users/Asha Anandan/Documents/Study Materials/Portfolio Projects/Project 1 E-commerce Customer Intelligence/Outputs/Output_Cohort/"


# In[6]:


f = pd.read_csv("C:/Users/Asha Anandan/Documents/Study Materials/Portfolio Projects/Project 1 E-commerce Customer Intelligence/Outputs/Output_data/fact_transactions_clean.csv.gz",
                dtype={"InvoiceNo": str, "StockCode": str},
                parse_dates=["InvoiceDate"])


# In[7]:


# 0. BASE POPULATION
# ---------------------------------------------------------------------------
# - Customer analytics need a CustomerID           -> HasCustomerID
# - Count purchases, not returns                   -> Quantity > 0 (Sale invoices)
# - Real merchandise only (no postage/fees/etc.)   -> IsProduct

sales = f[f["HasCustomerID"] & f["IsProduct"] & (f["Quantity"] > 0)].copy()
sales["CustomerID"] = sales["CustomerID"].astype(int)
print(f"Sales lines used: {len(sales):,} | customers: {sales.CustomerID.nunique():,}")


# In[8]:


# RFM
# ===========================================================================
# Snapshot = the day after the last transaction, so Recency is never 0.
snapshot = sales["InvoiceDate"].max().normalize() + pd.Timedelta(days=1)

rfm = (sales.groupby("CustomerID")
       .agg(LastPurchase=("InvoiceDate", "max"),
            Frequency=("InvoiceNo", "nunique"),          # distinct invoices
            Monetary=("LineTotal", "sum")))              # GBP spent
rfm["Recency"] = (snapshot - rfm["LastPurchase"].dt.normalize()).dt.days

# Scores 1-5 (5 = best). Recency: fewer days is better, so labels are reversed.
# Frequency uses rank(first) because many customers share the same low counts
# and qcut would otherwise fail on duplicate bin edges.
rfm["R"] = pd.qcut(rfm["Recency"], 5, labels=[5, 4, 3, 2, 1]).astype(int)
rfm["F"] = pd.qcut(rfm["Frequency"].rank(method="first"), 5, labels=[1, 2, 3, 4, 5]).astype(int)
rfm["M"] = pd.qcut(rfm["Monetary"], 5, labels=[1, 2, 3, 4, 5]).astype(int)
rfm["RFM_Score"] = rfm["R"].astype(str) + rfm["F"].astype(str) + rfm["M"].astype(str)


# In[9]:


rfm


# In[10]:


segments = {
    "CHAMPIONS":          [555, 554, 544, 545, 454, 455, 445],
    "LOYAL":              [543, 444, 435, 355, 354, 345, 344, 335],
    "POTENTIAL_LOYALIST": [553, 551, 552, 541, 542, 533, 532, 531, 452, 451, 442, 441,
                           431, 453, 433, 432, 423, 353, 352, 351, 342, 341, 333, 323],
    "RECENT_CUSTOMERS":   [512, 511, 422, 421, 412, 411, 311],
    "PROMISING":          [525, 524, 523, 522, 521, 515, 514, 513, 425, 424, 413, 414,
                           415, 315, 314, 313],
    "NEED_ATTENTION":     [535, 534, 443, 434, 343, 334, 325, 324],
    "ABOUT_TO_SLEEP":     [331, 321, 312, 221, 213, 231, 241, 251],
    "AT_RISK":            [255, 254, 245, 244, 253, 252, 243, 242, 235, 234, 225, 224,
                           153, 152, 145, 143, 142, 135, 134, 133, 125, 124],
    "CANNOT_LOSE":        [155, 154, 144, 214, 215, 115, 114, 113],
    "HIBERNATING":        [332, 322, 231, 241, 251, 233, 232, 223, 222, 132, 123, 122,
                           212, 211],
    "LOST":               [111, 112, 121, 131, 141, 151],
}

# score -> segment (setdefault keeps the FIRST segment if a score is listed twice)
lookup = {}
for name, scores in segments.items():
    for s in scores:
        lookup.setdefault(s, name)

rfm["RFM_Score"] = rfm["RFM_Score"].astype(int)

rfm["Segment"] = rfm["RFM_Score"].map(lookup)
#print(df["Segment"].value_counts())


# In[11]:


#print(rfm["RFM_Score"].dtype)
#print(rfm["RFM_Score"].head())
#print(type(rfm["RFM_Score"].iloc[0]))


# In[12]:


seg = (rfm.groupby("Segment")
       .agg(Customers=("Monetary", "size"),
            AvgRecencyDays=("Recency", "mean"),
            AvgFrequency=("Frequency", "mean"),
            AvgMonetary=("Monetary", "mean"),
            TotalRevenue=("Monetary", "sum")))
seg["PctCustomers"] = seg["Customers"] / seg["Customers"].sum() * 100
seg["PctRevenue"] = seg["TotalRevenue"] / seg["TotalRevenue"].sum() * 100
seg = seg.sort_values("TotalRevenue", ascending=False).round(1)
print("\nRFM segment summary\n", seg.to_string())


# In[13]:


rfm.reset_index().to_csv(f"{OUTPUT_RFM}/rfm_customers.csv", index=False)
seg.reset_index().to_csv(f"{OUTPUT_RFM}/rfm_segment_summary.csv", index=False)


# In[14]:


# COHORT RETENTION
# ===========================================================================
# Cohort = month of the customer's FIRST purchase.
# Activity = a month in which the customer placed >=1 invoice.
# Retention(n) = share of the cohort active n months after the cohort month.

sales["OrderMonth"] = sales["InvoiceDate"].dt.to_period("M")
sales["CohortMonth"] = sales.groupby("CustomerID")["OrderMonth"].transform("min")
sales["MonthIndex"] = ((sales["OrderMonth"].dt.year - sales["CohortMonth"].dt.year) * 12
                       + (sales["OrderMonth"].dt.month - sales["CohortMonth"].dt.month))


# In[15]:


sales[["InvoiceNo", "CustomerID","InvoiceDate","OrderMonth","CohortMonth","MonthIndex"]]


# In[16]:


counts = (sales.groupby(["CohortMonth", "MonthIndex"])["CustomerID"].nunique()
          .unstack(fill_value=0))
size = counts[0]
retention = counts.div(size, axis=0) * 100
retention = retention.round(0).astype(int).astype(str) + "%"


# In[17]:


last_month = sales["OrderMonth"].max()


# In[18]:


last_month


# In[19]:


retention


# In[20]:


for c in retention.index:
    max_idx = (last_month.year - c.year) * 12 + (last_month.month - c.month)
    retention.loc[c, retention.columns > max_idx] = np.nan
    
retention.index = retention.index.astype(str)
counts.index = counts.index.astype(str)


# In[21]:


retention.to_csv(f"{OUTPUT_COHORT}/cohort_retention_pct.csv")
counts.to_csv(f"{OUTPUT_COHORT}/cohort_retention_counts.csv")


# In[22]:


#Order Basket
OUTPUT_BASKET = "C:/Users/Asha Anandan/Documents/Study Materials/Portfolio Projects/Project 1 E-commerce Customer Intelligence/Outputs/Output_Basket/"
import os
os.makedirs(OUTPUT_BASKET, exist_ok=True)


# In[23]:


order_summary = (f[f["InvoiceType"] == "Sale"]
                 .groupby("InvoiceNo", as_index=False)
                 .agg(OrderDate=("InvoiceDate", "min"),
                      Country=("Country", "min"),
                      OrderValue=("LineTotal", "sum")))
order_summary = order_summary[order_summary["OrderValue"] > 0]


# In[26]:


# Order Value Band: same thresholds as the DAX SWITCH (upper bound inclusive)
band_edges = [0, 25, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900,
              1000, 2000, 3000, 4000, 5000, np.inf]
band_labels = ["£0–£25", "£25–£50", "£50–£100", "£100–£200", "£200–£300",
               "£300–£400", "£400–£500", "£500–£600", "£600–£700", "£700–£800",
               "£800–£900", "£900–£1000", "£1000–£2000", "£2000–£3000",
               "£3000–£4000", "£4000–£5000", "£5000+"]

order_summary["OrderValueBand"] = pd.cut(order_summary["OrderValue"],
                                         bins=band_edges,
                                         labels=band_labels,
                                         right=True).astype(str)

print(f"Order Summary: {len(order_summary):,} orders")
print(order_summary["OrderValueBand"].value_counts().reindex(band_labels))
order_summary.to_csv(f"{OUTPUT_BASKET}/order_summary.csv", index=False,
                     encoding="utf-8-sig")


# In[38]:


# PRODUCT ORDERS  (DAX: Product Orders)
# ===========================================================================
# Distinct (InvoiceNo, StockCode, Description) for real products that were sold.


# In[39]:


product_orders = (f[f["IsProduct"]
                    & (f["Quantity"] > 0)
                    & f["InvoiceNo"].notna()
                    & f["StockCode"].notna()]
                  [["InvoiceNo", "StockCode", "Description"]]
                  .drop_duplicates()
                  .reset_index(drop=True))


# In[40]:


print(f"Product Orders: {len(product_orders):,} rows")
product_orders.to_csv(f"{OUTPUT_BASKET}/product_orders.csv", index=False)


# In[41]:


# PRODUCT PAIRS  (DAX: Product Pairs)
# ===========================================================================
# Every pair of products bought on the same invoice. CodeA < CodeB keeps each
# pair once (no A-A, and no B-A duplicate of A-B).


# In[42]:


# 1) Compact integer codes (int32 instead of Python strings)
po = product_orders[["InvoiceNo", "StockCode"]].drop_duplicates().copy()
po["Inv"]  = po["InvoiceNo"].astype("category").cat.codes.astype("int32")
stock_cat  = po["StockCode"].astype("category")
stock_names = stock_cat.cat.categories                  # code -> StockCode
po["Code"] = stock_cat.cat.codes.astype("int32")
po = po[["Inv", "Code"]].sort_values("Inv").reset_index(drop=True)


# In[43]:


# 2) Process invoices in batches; each batch only creates a small merge
n_inv = po["Inv"].max() + 1
batch_size = 2000                                        # lower if memory is still tight
partials = []

for lo in range(0, n_inv, batch_size):
    hi = lo + batch_size
    sub = po[(po["Inv"] >= lo) & (po["Inv"] < hi)]
    m = sub.merge(sub, on="Inv", suffixes=("_A", "_B"))
    m = m[m["Code_A"] < m["Code_B"]]
    partials.append(m.groupby(["Code_A", "Code_B"]).size().rename("n").reset_index())

pair_counts = (pd.concat(partials)
               .groupby(["Code_A", "Code_B"], as_index=False)["n"].sum()
               .rename(columns={"n": "Orders Together"}))


# In[44]:


# 3) Map codes back to StockCode and one description per StockCode
#    (most common description, so a code with several names doesn't duplicate pairs)
desc = (product_orders.dropna(subset=["Description"])
        .groupby("StockCode")["Description"]
        .agg(lambda s: s.mode().iat[0]))

pair_counts["Product A Code"] = stock_names[pair_counts["Code_A"]].values
pair_counts["Product B Code"] = stock_names[pair_counts["Code_B"]].values
pair_counts["Product A"] = pair_counts["Product A Code"].map(desc)
pair_counts["Product B"] = pair_counts["Product B Code"].map(desc)

product_pairs_summary = (pair_counts
    [["Product A Code", "Product A", "Product B Code", "Product B", "Orders Together"]]
    .sort_values("Orders Together", ascending=False)
    .reset_index(drop=True))

print(f"Distinct product pairs: {len(product_pairs_summary):,}")
product_pairs_summary.to_csv(f"{OUTPUT_BASKET}/product_pairs_summary.csv",
                             index=False, encoding="utf-8-sig")


# In[45]:


# Smaller file for Power BI: drop pairs seen in fewer than 5 invoices
product_pairs_summary[product_pairs_summary["Orders Together"] >= 5]     .to_csv(f"{OUTPUT_BASKET}/product_pairs_summary_min5.csv",
            index=False, encoding="utf-8-sig")


# In[ ]:




