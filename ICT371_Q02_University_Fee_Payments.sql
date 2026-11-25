-- ICT371 Advanced Databases | Question 2
-- University Fee Payments
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q02.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The seed data leaves Mary with zero payments and settles David’s fee in full. Run the
-- six payment calls after parts (b)–(d).
CREATE SCHEMA ict371_q02;
SET search_path = ict371_q02, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE students (
    student_id integer PRIMARY KEY,
    student_number text NOT NULL UNIQUE,
    full_name text NOT NULL,
    fee_due numeric(12,2) NOT NULL
        CHECK (fee_due >= 0 AND fee_due <> 'NaN')
);

CREATE TABLE payments (
    payment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id integer NOT NULL REFERENCES students,
    amount numeric(12,2) NOT NULL
        CHECK (amount > 0 AND amount <> 'NaN'),
    paid_on date NOT NULL CHECK (isfinite(paid_on))
);

CREATE TABLE payment_audit (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id bigint NOT NULL REFERENCES payments,
    student_id integer NOT NULL REFERENCES students,
    amount numeric(12,2) NOT NULL,
    logged_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE daily_collections (
    collection_date date PRIMARY KEY,
    payment_count bigint NOT NULL CHECK (payment_count >= 0),
    total_amount numeric NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO students VALUES
    (1, 'ST001', 'Ruth Banda', 5000.00),
    (2, 'ST002', 'David Phiri', 3600.00),
    (3, 'ST003', 'Mary Zulu', 4200.00);

-- (b) Function
-- COALESCE treats the absence of payments as a zero total, so the function returns the
-- full fee in that case.
CREATE FUNCTION fn_fee_balance(p_student_id integer)
RETURNS numeric LANGUAGE plpgsql SET search_path = ict371_q02, pg_catalog AS $$
DECLARE
    v_balance numeric;
BEGIN
    SELECT s.fee_due - COALESCE((
        SELECT SUM(p.amount)
        FROM payments AS p WHERE p.student_id = s.student_id
    ), 0) INTO v_balance
    FROM students AS s WHERE s.student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;
    RETURN v_balance;
END;
$$;

-- (c) Procedure
-- At PostgreSQL’s default READ COMMITTED isolation level, the student row lock
-- serializes payment calls for that student. The balance is read after acquiring the
-- lock. The procedure only writes to payments.
CREATE PROCEDURE pr_receive_payment(
    p_student_id integer, p_amount numeric, p_paid_on date
)
LANGUAGE plpgsql SET search_path = ict371_q02, pg_catalog AS $$
DECLARE
    v_balance numeric;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0
       OR p_amount >= 'Infinity'::numeric
       OR p_amount <> ROUND(p_amount, 2) THEN
        RAISE EXCEPTION 'Enter a positive finite amount in whole cents';
    END IF;
    IF p_paid_on IS NULL OR NOT isfinite(p_paid_on) THEN
        RAISE EXCEPTION 'A valid payment date is required';
    END IF;

    PERFORM 1 FROM students
    WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment exceeds balance of %', v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger
-- Each inserted payment produces one audit row. The default on logged_at supplies the
-- timestamp.
CREATE FUNCTION fn_audit_payment()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q02, pg_catalog AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_payment
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION fn_audit_payment();

-- (a) Deferred seed data, loaded after the routines and trigger
CALL pr_receive_payment(1, 1000.00, DATE '2026-11-23');
CALL pr_receive_payment(1, 750.00, DATE '2026-11-23');
CALL pr_receive_payment(1, 500.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1200.00, DATE '2026-11-23');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1400.00, DATE '2026-11-24');

-- (e) View
-- The left join includes students with zero payments. The seeded view shows Ruth owing
-- K2,750.00 and Mary owing K4,200.00.
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students AS s
LEFT JOIN payments AS p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;

-- (f) Index and execution plan
-- The index orders entries by student first and then payment date, so a date-range scan
-- can start within one student’s entries.
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

EXPLAIN (COSTS OFF)
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-23' AND DATE '2026-11-24';

-- Plan observed on the seed dataset:
-- Seq Scan on payments
--   Filter: ((paid_on >= '2026-11-23'::date) AND (paid_on <= '2026-11-24'::date) AND (student_id = 1))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_payments_student_date on payments
--   Index Cond: ((student_id = 1) AND (paid_on >= '2026-11-23'::date) AND (paid_on <= '2026-11-24'::date))

-- (g) Scheduled job
-- The job runs daily at 01:00 for the previous day. The upsert replaces both values if
-- the date already exists.
CREATE PROCEDURE pr_refresh_collections(p_day date)
LANGUAGE plpgsql SET search_path = ict371_q02, pg_catalog AS $$
BEGIN
    IF p_day IS NULL OR NOT isfinite(p_day) THEN
        RAISE EXCEPTION 'A valid collection date is required';
    END IF;

    INSERT INTO daily_collections
        (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_refresh_collections(DATE '2026-11-23');
CALL pr_refresh_collections(DATE '2026-11-23');
CALL pr_refresh_collections(DATE '2026-11-24');
SELECT * FROM daily_collections ORDER BY collection_date;
ROLLBACK;

-- Expected results are 3 payments totaling K2,950.00 on 23 November and 3 payments
-- totaling K2,900.00 on 24 November.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q02',
    '0 1 * * *',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q02.pr_refresh_collections((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);
    $job$
);
*/
