-- SalesOps Control Tower: SLA audit and payment reconciliation (SQLite dialect)
-- Parameters, passed from the notebook:
--   :as_of  :sla_target  :zombie_days  :stall_days  :recon_window
-- Tables: crm_orders, wms_pos_logistics, finance_invoices, finance_collections, dim_calendar

-- Query 1: order lifecycle, business days per step, SLA status and inventory flags
WITH base AS (
    SELECT o.order_id, o.merchant_id, o.city, o.city_tier, o.sales_channel,
           o.kyc_status, o.kyc_rejection_reason, o.payment_date, o.kyc_decision_date,
           w.pos_model, w.pos_serial, w.carrier, w.logistics_status,
           w.dispatch_date, w.carrier_last_update_date, w.carrier_delivery_date, w.first_transaction_date
    FROM crm_orders o
    LEFT JOIN wms_pos_logistics w ON w.order_id = o.order_id      -- orders blocked by KYC have no WMS row
),
stage_days AS (
    SELECT b.*,
           kyc.bday_seq - pay.bday_seq   AS bd_kyc,
           dsp.bday_seq - kyc.bday_seq   AS bd_dispatch,
           dlv.bday_seq - dsp.bday_seq   AS bd_transit,
           txn.bday_seq - dlv.bday_seq   AS bd_activation,
           txn.bday_seq - pay.bday_seq   AS bd_total,            -- NULL until the first transaction happens
           asof.bday_seq - pay.bday_seq  AS bd_open_age,         -- how old the order is today
           CAST(julianday(:as_of) - julianday(b.carrier_delivery_date)    AS INTEGER) AS days_since_delivery,
           CAST(julianday(:as_of) - julianday(b.carrier_last_update_date) AS INTEGER) AS days_since_carrier_update
    FROM base b
    LEFT JOIN dim_calendar pay  ON pay.date  = b.payment_date
    LEFT JOIN dim_calendar kyc  ON kyc.date  = b.kyc_decision_date
    LEFT JOIN dim_calendar dsp  ON dsp.date  = b.dispatch_date
    LEFT JOIN dim_calendar dlv  ON dlv.date  = b.carrier_delivery_date
    LEFT JOIN dim_calendar txn  ON txn.date  = b.first_transaction_date
    LEFT JOIN dim_calendar asof ON asof.date = :as_of
)
SELECT s.*,
       CASE
           WHEN kyc_status = 'Rejected'          THEN 'Not applicable - KYC rejected'
           WHEN bd_total IS NOT NULL AND bd_total <= :sla_target THEN 'Completed on time'
           WHEN bd_total IS NOT NULL             THEN 'Completed late'
           WHEN bd_open_age > :sla_target        THEN 'Open - already late'
           ELSE 'Open - within SLA'
       END AS sla_status,
       CASE WHEN logistics_status = 'Delivered' AND days_since_delivery > :zombie_days THEN 1 ELSE 0 END AS is_zombie_pos,
       CASE WHEN logistics_status = 'In transit' AND days_since_carrier_update > :stall_days THEN 1 ELSE 0 END AS is_stalled_in_transit,
       bd_total - AVG(bd_total) OVER (PARTITION BY city_tier) AS bd_vs_tier_avg
FROM stage_days s;

-- Query 2: invoice vs bank collection, one row per order
WITH inv AS (
    SELECT order_id, SUM(billed_amount_cop) AS billed_cop, MIN(invoice_date) AS invoice_date
    FROM finance_invoices GROUP BY order_id
),
col AS (
    SELECT order_id, SUM(collected_amount_cop) AS collected_cop, COUNT(*) AS n_bank_rows
    FROM finance_collections GROUP BY order_id            -- one row per order before joining
),
all_orders AS (
    SELECT order_id FROM inv
    UNION
    SELECT order_id FROM col                              -- keeps orders that exist on only one side
)
SELECT a.order_id, i.invoice_date, i.billed_cop, c.collected_cop, c.n_bank_rows,
       COALESCE(c.collected_cop, 0) - COALESCE(i.billed_cop, 0) AS difference_cop,
       CASE
           WHEN i.order_id IS NULL                                            THEN 'Collected without invoice'
           WHEN c.order_id IS NULL
                AND julianday(:as_of) - julianday(i.invoice_date) <= :recon_window THEN 'Pending - within window'
           WHEN c.order_id IS NULL OR c.collected_cop = 0                     THEN 'Invoiced without collection'
           WHEN c.collected_cop = i.billed_cop                                THEN 'Reconciled'
           WHEN c.collected_cop > i.billed_cop                                THEN 'Amount difference - over-collected'
           ELSE                                                                    'Amount difference - under-collected'
       END AS reconciliation_status
FROM all_orders a
LEFT JOIN inv i ON i.order_id = a.order_id
LEFT JOIN col c ON c.order_id = a.order_id;
