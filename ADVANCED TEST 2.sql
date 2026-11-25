---QUESTION 2 - UNIVERSITY FEESQ2 (a) - Tables + Seed [6]
CREATE DATABASE IF NOT EXISTS university_fees_db;
USE university_fees_db;

CREATE TABLE students (
    student_id INT AUTO_INCREMENT PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due DECIMAL(10,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL DEFAULT (CURRENT_DATE),
    FOREIGN KEY (student_id) REFERENCES students(student_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE payment_audit (
    audit_id INT AUTO_INCREMENT PRIMARY KEY,
    payment_id INT NOT NULL,
    student_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    logged_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (payment_id) REFERENCES payments(payment_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
    FOREIGN KEY (student_id) REFERENCES students(student_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
('2026-001', 'Wakunoli Sanalumba', 5000.00),
('2026-002', 'Chanda Mwila', 3000.00),
('2026-003', 'Mutinta Banda', 4500.00);
-- Student 3 has NO payments initially

-- After (c) is created, run 6 payments:
CALL pr_receive_payment(1, 1000.00, '2026-11-24');
CALL pr_receive_payment(1, 1500.00, '2026-11-24');
CALL pr_receive_payment(1, 500.00,  '2026-11-24');
CALL pr_receive_payment(1, 500.00,  '2026-11-25');
CALL pr_receive_payment(2, 1000.00, '2026-11-24');
CALL pr_receive_payment(2, 2000.00, '2026-11-25');
-- Balances: S1 owes 1500, S2 owes 0, S3 owes 4500

----Q2 (b) - Function [6]

DELIMITER //
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS DECIMAL(12,2) DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_fee_due DECIMAL(10,2);
    DECLARE v_paid DECIMAL(12,2);
    SELECT fee_due INTO v_fee_due FROM students WHERE student_id = p_student_id;
    IF v_fee_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee_due - v_paid;
END //
DELIMITER ;

SELECT fn_fee_balance(1); -- 1500
SELECT fn_fee_balance(2); -- 0
SELECT fn_fee_balance(3); -- 4500, full fee, no payments
SELECT fn_fee_balance(999); -- error


----Q2 (c) - Procedure [8]

DELIMITER //
CREATE PROCEDURE pr_receive_payment(IN p_student_id INT, IN p_amount DECIMAL(10,2), IN p_paid_on DATE)
BEGIN
    DECLARE v_fee_due DECIMAL(10,2);
    DECLARE v_paid DECIMAL(12,2);
    DECLARE v_balance DECIMAL(12,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be positive';
    END IF;
    SELECT fee_due INTO v_fee_due FROM students WHERE student_id = p_student_id;
    IF v_fee_due IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student not found';
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    SET v_balance = v_fee_due - v_paid;
    IF p_amount > v_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds outstanding balance';
    END IF;
    START TRANSACTION;
        INSERT INTO payments (student_id, amount, paid_on)
        VALUES (p_student_id, p_amount, p_paid_on);
    COMMIT;
END //
DELIMITER ;

CALL pr_receive_payment(1, 500.00, '2026-11-24'); -- valid, fee_due UNCHANGED
CALL pr_receive_payment(1, 5000.00, '2026-11-24'); -- reject, above balance
CALL pr_receive_payment(1, 0, '2026-11-24'); -- reject
CALL pr_receive_payment(1, -100.00, '2026-11-24'); -- reject




----Q2 (d) - Trigger [8]

DELIMITER //
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
END //
DELIMITER ;

CALL pr_receive_payment(3, 1000.00, '2026-11-24'); -- trigger creates audit automatically

---Q2 (e) - View [5]

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_id, s.student_number, s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING outstanding_balance > 0;

SELECT * FROM v_fee_balances;
-- LEFT JOIN = no-payment students still show full fee. HAVING > 0 excludes fully settled.

---Q2 (f) - Index [5]

CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

EXPLAIN SELECT payment_id, student_id, amount, paid_on FROM payments
WHERE student_id = 1 AND paid_on BETWEEN '2026-11-24' AND '2026-11-25';
-- Justification: student_id = equality first, paid_on = range second.
-- Seeks to that student, scans only date range, avoids full scan / filesort.
-- Do NOT put paid_on first.

Q2 (g) - Scheduled Job [6]

DELIMITER //
CREATE PROCEDURE pr_refresh_collections(IN p_day DATE)
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_total DECIMAL(12,2) DEFAULT 0.00;
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00) INTO v_count, v_total
    FROM payments WHERE paid_on = p_day;
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_total)
    ON DUPLICATE KEY UPDATE payment_count = v_count, total_amount = v_total;
END //
DELIMITER ;

CALL pr_refresh_collections('2026-11-24');
CALL pr_refresh_collections('2026-11-24'); -- run twice, must NOT double

SET GLOBAL event_scheduler = ON;
CREATE EVENT ev_refresh_daily_collections
ON SCHEDULE EVERY 1 DAY STARTS '2026-11-25 01:00:00'
ON COMPLETION PRESERVE ENABLE
DO CALL pr_refresh_collections(DATE_SUB(CURRENT_DATE, INTERVAL 1 DAY));























































