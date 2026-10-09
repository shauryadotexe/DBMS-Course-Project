DROP DATABASE IF EXISTS attendance_leave_db;
CREATE DATABASE attendance_leave_db;
USE attendance_leave_db;


CREATE TABLE department (
    dept_id     INT AUTO_INCREMENT PRIMARY KEY,
    dept_name   VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE faculty (
    faculty_id  INT AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(80)  NOT NULL,
    email       VARCHAR(100) NOT NULL UNIQUE,
    dept_id     INT NOT NULL,
    is_hod      BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (dept_id) REFERENCES department(dept_id)
);

CREATE TABLE student (
    student_id  INT AUTO_INCREMENT PRIMARY KEY,
    roll_no     VARCHAR(20)  NOT NULL UNIQUE,
    full_name   VARCHAR(80)  NOT NULL,
    email       VARCHAR(100) NOT NULL UNIQUE,
    phone       VARCHAR(15),
    dept_id     INT NOT NULL,
    semester    TINYINT NOT NULL CHECK (semester BETWEEN 1 AND 8),
    mentor_id   INT NOT NULL,
    FOREIGN KEY (dept_id)   REFERENCES department(dept_id),
    FOREIGN KEY (mentor_id) REFERENCES faculty(faculty_id)
);

CREATE TABLE course (
    course_id   INT AUTO_INCREMENT PRIMARY KEY,
    course_code VARCHAR(15) NOT NULL UNIQUE,
    course_name VARCHAR(100) NOT NULL,
    credits     TINYINT NOT NULL CHECK (credits > 0),
    dept_id     INT NOT NULL,
    faculty_id  INT NOT NULL,
    FOREIGN KEY (dept_id)    REFERENCES department(dept_id),
    FOREIGN KEY (faculty_id) REFERENCES faculty(faculty_id)
);

CREATE TABLE enrollment (
    enrollment_id INT AUTO_INCREMENT PRIMARY KEY,
    student_id    INT NOT NULL,
    course_id     INT NOT NULL,
    academic_year VARCHAR(9) NOT NULL,            
    UNIQUE (student_id, course_id, academic_year),
    FOREIGN KEY (student_id) REFERENCES student(student_id) ON DELETE CASCADE,
    FOREIGN KEY (course_id)  REFERENCES course(course_id)
);

CREATE TABLE class_session (
    session_id   INT AUTO_INCREMENT PRIMARY KEY,
    course_id    INT NOT NULL,
    session_date DATE NOT NULL,
    start_time   TIME NOT NULL,
    end_time     TIME NOT NULL,
    topic        VARCHAR(150),
    CHECK (end_time > start_time),
    UNIQUE (course_id, session_date, start_time),
    FOREIGN KEY (course_id) REFERENCES course(course_id)
);

CREATE TABLE attendance (
    attendance_id INT AUTO_INCREMENT PRIMARY KEY,
    session_id    INT NOT NULL,
    student_id    INT NOT NULL,
    status        ENUM('Present','Absent','On Leave') NOT NULL,
    marked_by     INT NOT NULL,
    marked_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (session_id, student_id),
    FOREIGN KEY (session_id) REFERENCES class_session(session_id) ON DELETE CASCADE,
    FOREIGN KEY (student_id) REFERENCES student(student_id) ON DELETE CASCADE,
    FOREIGN KEY (marked_by)  REFERENCES faculty(faculty_id)
);

CREATE TABLE leave_type (
    leave_type_id    INT AUTO_INCREMENT PRIMARY KEY,
    type_name        VARCHAR(40) NOT NULL UNIQUE,
    max_days_per_sem TINYINT NOT NULL CHECK (max_days_per_sem > 0)
);

CREATE TABLE leave_request (
    leave_id      INT AUTO_INCREMENT PRIMARY KEY,
    student_id    INT NOT NULL,
    leave_type_id INT NOT NULL,
    from_date     DATE NOT NULL,
    to_date       DATE NOT NULL,
    reason        VARCHAR(255) NOT NULL,
    status        ENUM('Pending','Mentor Approved','Approved','Rejected','Cancelled')
                  NOT NULL DEFAULT 'Pending',
    applied_on    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (to_date >= from_date),
    FOREIGN KEY (student_id)    REFERENCES student(student_id) ON DELETE CASCADE,
    FOREIGN KEY (leave_type_id) REFERENCES leave_type(leave_type_id)
);


CREATE TABLE leave_approval (
    approval_id INT AUTO_INCREMENT PRIMARY KEY,
    leave_id    INT NOT NULL,
    approver_id INT NOT NULL,
    level       ENUM('Mentor','HOD') NOT NULL,
    decision    ENUM('Approved','Rejected') NOT NULL,
    remarks     VARCHAR(255),
    decided_on  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (leave_id, level),
    FOREIGN KEY (leave_id)    REFERENCES leave_request(leave_id) ON DELETE CASCADE,
    FOREIGN KEY (approver_id) REFERENCES faculty(faculty_id)
);

CREATE INDEX idx_att_student   ON attendance(student_id);
CREATE INDEX idx_leave_student ON leave_request(student_id, status);
CREATE INDEX idx_session_date  ON class_session(session_date);


CREATE VIEW v_attendance_percentage AS
SELECT  s.student_id, s.roll_no, s.full_name,
        c.course_code, c.course_name,
        SUM(a.status = 'Present')                     AS attended,
        SUM(a.status <> 'On Leave')                    AS conducted,
        ROUND(100 * SUM(a.status = 'Present')
              / NULLIF(SUM(a.status <> 'On Leave'),0), 2) AS attendance_pct
FROM attendance a
JOIN student s       ON s.student_id = a.student_id
JOIN class_session cs ON cs.session_id = a.session_id
JOIN course c        ON c.course_id = cs.course_id
GROUP BY s.student_id, s.roll_no, s.full_name, c.course_id, c.course_code, c.course_name;

-- Pending work for approvers
CREATE VIEW v_pending_leaves AS
SELECT  lr.leave_id, s.roll_no, s.full_name, lt.type_name,
        lr.from_date, lr.to_date,
        DATEDIFF(lr.to_date, lr.from_date) + 1 AS days,
        lr.status, lr.status = 'Pending' AS awaiting_mentor,
        s.mentor_id
FROM leave_request lr
JOIN student s     ON s.student_id = lr.student_id
JOIN leave_type lt ON lt.leave_type_id = lr.leave_type_id
WHERE lr.status IN ('Pending','Mentor Approved');


DELIMITER $$

CREATE PROCEDURE sp_apply_leave(
    IN p_student_id INT, IN p_leave_type_id INT,
    IN p_from DATE, IN p_to DATE, IN p_reason VARCHAR(255))
BEGIN
    DECLARE v_used INT DEFAULT 0;
    DECLARE v_max  INT;
    DECLARE v_req  INT;

    IF p_to < p_from THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'To-date cannot be before from-date';
    END IF;

    IF EXISTS (SELECT 1 FROM leave_request
               WHERE student_id = p_student_id
                 AND status IN ('Pending','Mentor Approved','Approved')
                 AND p_from <= to_date AND p_to >= from_date) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Overlapping leave request exists';
    END IF;

    SET v_req = DATEDIFF(p_to, p_from) + 1;
    SELECT max_days_per_sem INTO v_max FROM leave_type WHERE leave_type_id = p_leave_type_id;

    SELECT COALESCE(SUM(DATEDIFF(to_date, from_date) + 1), 0) INTO v_used
    FROM leave_request
    WHERE student_id = p_student_id AND leave_type_id = p_leave_type_id
      AND status IN ('Approved','Mentor Approved','Pending');

    IF v_used + v_req > v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Leave balance exceeded for this leave type';
    END IF;

    INSERT INTO leave_request(student_id, leave_type_id, from_date, to_date, reason)
    VALUES (p_student_id, p_leave_type_id, p_from, p_to, p_reason);
END$$

CREATE TRIGGER trg_approval_before_insert
BEFORE INSERT ON leave_approval
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(20);
    SELECT status INTO v_status FROM leave_request WHERE leave_id = NEW.leave_id;

    IF v_status IN ('Approved','Rejected','Cancelled') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Leave request is already closed';
    END IF;
    IF NEW.level = 'Mentor' AND v_status <> 'Pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mentor decision already recorded';
    END IF;
    IF NEW.level = 'HOD' AND v_status <> 'Mentor Approved' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'HOD can act only after mentor approval';
    END IF;
END$$

CREATE TRIGGER trg_approval_after_insert
AFTER INSERT ON leave_approval
FOR EACH ROW
BEGIN
    IF NEW.decision = 'Rejected' THEN
        UPDATE leave_request SET status = 'Rejected' WHERE leave_id = NEW.leave_id;
    ELSEIF NEW.level = 'Mentor' THEN
        UPDATE leave_request SET status = 'Mentor Approved' WHERE leave_id = NEW.leave_id;
    ELSE
        UPDATE leave_request SET status = 'Approved' WHERE leave_id = NEW.leave_id;

        UPDATE attendance a
        JOIN class_session cs ON cs.session_id = a.session_id
        JOIN leave_request lr ON lr.leave_id = NEW.leave_id
                             AND lr.student_id = a.student_id
        SET a.status = 'On Leave'
        WHERE cs.session_date BETWEEN lr.from_date AND lr.to_date;
    END IF;
END$$

DELIMITER ;


INSERT INTO department(dept_name) VALUES ('Computer Science'), ('Business Administration');

INSERT INTO faculty(full_name, email, dept_id, is_hod) VALUES
 ('Dr. Anita Rao',  'anita.rao@uni.edu',  1, TRUE),
 ('Prof. Kiran Das','kiran.das@uni.edu',  1, FALSE),
 ('Dr. Meera Nair', 'meera.nair@uni.edu', 2, TRUE);

INSERT INTO student(roll_no, full_name, email, phone, dept_id, semester, mentor_id) VALUES
 ('CS101','Rahul Verma', 'rahul@uni.edu', '9000000001', 1, 3, 2),
 ('CS102','Sneha Reddy', 'sneha@uni.edu', '9000000002', 1, 3, 2),
 ('BA201','Arjun Mehta', 'arjun@uni.edu', '9000000003', 2, 3, 3);

INSERT INTO course(course_code, course_name, credits, dept_id, faculty_id) VALUES
 ('CS301','Database Management Systems', 4, 1, 2),
 ('CS302','Operating Systems',           3, 1, 1);

INSERT INTO enrollment(student_id, course_id, academic_year) VALUES
 (1,1,'2026-2027'),(2,1,'2026-2027'),(1,2,'2026-2027'),(2,2,'2026-2027');

INSERT INTO class_session(course_id, session_date, start_time, end_time, topic) VALUES
 (1,'2026-09-14','09:00','10:00','ER Modelling'),
 (1,'2026-09-15','09:00','10:00','Relational Algebra'),
 (1,'2026-09-16','09:00','10:00','Normalization'),
 (1,'2026-09-17','09:00','10:00','SQL Joins'),
 (2,'2026-09-14','11:00','12:00','Processes'),
 (2,'2026-09-15','11:00','12:00','Scheduling');

INSERT INTO attendance(session_id, student_id, status, marked_by) VALUES
 (1,1,'Present',2),(1,2,'Present',2),
 (2,1,'Absent', 2),(2,2,'Present',2),
 (3,1,'Absent', 2),(3,2,'Present',2),
 (4,1,'Present',2),(4,2,'Present',2),
 (5,1,'Present',1),(5,2,'Absent', 1),
 (6,1,'Absent', 1),(6,2,'Present',1);

INSERT INTO leave_type(type_name, max_days_per_sem) VALUES
 ('Medical',10),('Personal',5),('Academic Event',7);


CALL sp_apply_leave(1, 1, '2026-09-15', '2026-09-16', 'Fever, doctor advised rest');

INSERT INTO leave_approval(leave_id, approver_id, level, decision, remarks)
VALUES (1, 2, 'Mentor', 'Approved', 'Medical certificate verified');
INSERT INTO leave_approval(leave_id, approver_id, level, decision, remarks)
VALUES (1, 1, 'HOD', 'Approved', 'Approved');

CALL sp_apply_leave(2, 2, '2026-09-17', '2026-09-17', 'Family function');
INSERT INTO leave_approval(leave_id, approver_id, level, decision, remarks)
VALUES (2, 2, 'Mentor', 'Rejected', 'Internal test scheduled');


SELECT * FROM v_attendance_percentage ORDER BY roll_no, course_code;

SELECT roll_no, full_name, course_code, attendance_pct
FROM v_attendance_percentage
WHERE attendance_pct < 75;

SELECT s.roll_no, s.full_name,
       ROUND(100 * SUM(a.status = 'Present') / NULLIF(SUM(a.status <> 'On Leave'),0), 2) AS overall_pct
FROM student s JOIN attendance a ON a.student_id = s.student_id
GROUP BY s.student_id, s.roll_no, s.full_name;

SELECT lr.leave_id, s.full_name, lt.type_name, lr.from_date, lr.to_date,
       lr.status, la.level, f.full_name AS approver, la.decision, la.remarks
FROM leave_request lr
JOIN student s     ON s.student_id = lr.student_id
JOIN leave_type lt ON lt.leave_type_id = lr.leave_type_id
LEFT JOIN leave_approval la ON la.leave_id = lr.leave_id
LEFT JOIN faculty f         ON f.faculty_id = la.approver_id
ORDER BY lr.leave_id, la.decided_on;

SELECT * FROM v_pending_leaves WHERE mentor_id = 2;

SELECT s.full_name, lt.type_name,
       SUM(DATEDIFF(lr.to_date, lr.from_date) + 1) AS days_used, lt.max_days_per_sem
FROM leave_request lr
JOIN student s     ON s.student_id = lr.student_id
JOIN leave_type lt ON lt.leave_type_id = lr.leave_type_id
WHERE lr.status = 'Approved'
GROUP BY s.student_id, s.full_name, lt.leave_type_id, lt.type_name, lt.max_days_per_sem;

SELECT c.course_code, cs.session_date, COUNT(*) AS absent_count
FROM attendance a
JOIN class_session cs ON cs.session_id = a.session_id
JOIN course c         ON c.course_id = cs.course_id
WHERE a.status = 'Absent'
GROUP BY c.course_code, cs.session_date;

SELECT roll_no, full_name FROM student
WHERE student_id NOT IN (SELECT student_id FROM leave_request);

SELECT f.full_name AS mentor, COUNT(*) AS rejected
FROM leave_approval la JOIN faculty f ON f.faculty_id = la.approver_id
WHERE la.level = 'Mentor' AND la.decision = 'Rejected'
GROUP BY f.faculty_id, f.full_name;