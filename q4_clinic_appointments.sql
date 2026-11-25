-- ICT371 Question 4: Clinic Appointment Scheduling (PostgreSQL)
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL,
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
  CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
  CONSTRAINT chk_slot   CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00'))
);

CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL DEFAULT 0,
  attended_count  INT NOT NULL DEFAULT 0,
  cancelled_count INT NOT NULL DEFAULT 0
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
  v_count INT;
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';

  RETURN v_count;      -- COUNT returns 0 when the day has no bookings
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
AS $$
BEGIN
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
  END IF;

  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;

  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
  END IF;

  IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: %', p_slot;
  END IF;

  INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks clashes
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_clash() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
       SELECT 1 FROM appointments a
       WHERE a.doctor_id = NEW.doctor_id
         AND a.appointment_day = NEW.appointment_day
         AND a.slot_time = NEW.slot_time
         AND a.status <> 'CANCELLED'
         AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)  -- exclude row being updated
     ) THEN
    RAISE EXCEPTION 'Slot clash: doctor % already booked on % at %',
      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

-- (g) PROCEDURE: clinic summary ------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
AS $$
BEGIN
  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA (after the trigger exists so every row is checked) -------
INSERT INTO patients (full_name) VALUES ('Grace Lungu'), ('Peter Kabwe'), ('Ruth Nkonde');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mulenga'), ('Dr. Banda'), ('Dr. Chisenga');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
  (1, 1, CURRENT_DATE,     TIME '09:00', 'BOOKED'),
  (2, 1, CURRENT_DATE,     TIME '10:00', 'BOOKED'),
  (3, 2, CURRENT_DATE,     TIME '09:00', 'BOOKED'),
  (1, 3, CURRENT_DATE - 1, TIME '11:00', 'ATTENDED'),
  (2, 2, CURRENT_DATE - 1, TIME '12:00', 'CANCELLED'),
  (3, 1, CURRENT_DATE + 1, TIME '09:00', 'BOOKED');

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, TIME '10:00');   -- booked via procedure

SELECT * FROM appointments ORDER BY appointment_id;

-- tests (each should raise an error)
-- SELECT fn_daily_load(1, CURRENT_DATE);                          -- 2
-- SELECT fn_daily_load(1, CURRENT_DATE + 30);                     -- 0
-- SELECT fn_daily_load(99, CURRENT_DATE);                         -- Unknown doctor
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00');     -- clash
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, TIME '09:00'); -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 3, TIME '13:00'); -- bad slot
-- UPDATE appointments SET slot_time = TIME '09:00' WHERE appointment_id = 2; -- clash on update
-- A cancelled slot can be rebooked: the cancelled row is ignored by the clash check.

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) INDEX --------------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);   -- rerun replaces the row
SELECT * FROM clinic_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
  $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
