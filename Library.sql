Library Returns and Overdue Fines
DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path TO q3_library;

(a) Tables and seed data
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(100) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE,                          -- NULL = not returned
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0,
    CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
('Database Systems'), ('Networks'), ('Algorithms');

6 loans, all open first (loans 3 and 4 are returned later by the procedure)
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
(1, 'Alice', '2026-11-01', '2026-11-15'),   -- 1 open, overdue
(1, 'Bob',   '2026-11-20', '2026-12-04'),   -- 2 open, not yet due
(2, 'Carol', '2026-10-01', '2026-10-15'),   -- 3 returned late
(2, 'Dan',   '2026-10-10', '2026-10-24'),   -- 4 returned on due date
(3, 'Eve',   '2026-11-05', '2026-11-12'),   -- 5 open, overdue
(3, 'Frank', '2026-11-11', '2026-11-25');   -- 6 open, due today

(b) Function: fine = K2 x overdue days, minimum 0
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE) RETURNS NUMERIC AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_ret
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan';
    END IF;
    -- use the earlier of as-of date and return date
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql;

SELECT fn_loan_fine(1, '2026-11-25');   -- 20 (10 days late)
SELECT fn_loan_fine(2, '2026-11-25');   -- 0

(c) Procedure: return a loan
CREATE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan';
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan already returned';
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date';
    END IF;
    --return date and final fine saved in ONE update
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

(d) Trigger: log changes to returned_on
CREATE FUNCTION trg_loan_audit_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit_fn();

-- Return loans 3 and 4 (trigger is now installed)
CALL pr_return_loan(3, '2026-10-20');   -- fine 10
CALL pr_return_loan(4, '2026-10-24');   -- fine 0

SELECT * FROM loans;
SELECT * FROM loan_audit;               -- 2 rows

-- Unchanged date: no new audit row
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 1;
SELECT * FROM loan_audit;               -- still 2 rows

-- Error tests: run each line alone
-- CALL pr_return_loan(3, '2026-10-25');   -- already returned
-- CALL pr_return_loan(99, CURRENT_DATE);  -- unknown loan
-- CALL pr_return_loan(1, '2026-10-01');   -- before borrowed_on

(e) View: unreturned loans past due date
CREATE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;          -- Alice and Eve

-- (f) Index: one book's unreturned loans
-- Justification: a partial index keeps only unreturned loans, so it is small
-- and the search by book_id goes straight to the right rows.
CREATE INDEX idx_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;

SET enable_seqscan = off;               -- table is tiny
EXPLAIN SELECT * FROM loans
WHERE book_id = 1 AND returned_on IS NULL;
SET enable_seqscan = on;

(g) Scheduled job: overdue snapshot
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE returned_on IS NULL AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue('2026-11-25');
CALL pr_refresh_overdue('2026-11-25');  -- rerun: still one row
SELECT * FROM overdue_summary;          -- count 2, total 46

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue', '10 0 * * *',
    $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$$);
SELECT * FROM cron.job;