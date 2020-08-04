#|
This file is a part of cl-mixed
(c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.mixed)

(defclass bip-buffer ()
  ())

(declaim (inline free-for-r2 free-after-r1))
(defun free-for-r2 (handle)
  (- (mixed:buffer-r1-start handle)
     (mixed:buffer-r2-start handle)
     (mixed:buffer-r2-size handle)))

(defun free-after-r1 (handle)
  (- (mixed:buffer-size handle)
     (mixed:buffer-r1-start handle)
     (mixed:buffer-r1-size handle)))

(defun available-read (buffer)
  (declare (optimize speed))
  (mixed:buffer-r1-size (handle buffer)))

(defun available-write (buffer)
  (declare (optimize speed))
  (let ((buffer (handle buffer)))
    (if (< 0 (mixed:buffer-r2-size buffer))
        (free-for-r2 buffer)
        (free-after-r1 buffer))))

(defun request-write (buffer size)
  (declare (optimize speed))
  (let ((buffer (handle buffer)))
    (cond ((< 0 (mixed:buffer-r2-size buffer))
           (let ((free (min size (free-for-r2 buffer)))
                 (start (+ (mixed:buffer-r2-start buffer) (mixed:buffer-r2-size buffer))))
             (setf (mixed:buffer-reserved-size buffer) free)
             (setf (mixed:buffer-reserved-start buffer) start)
             (values start (+ free start))))
          ((<= (mixed:buffer-r1-start buffer) (free-after-r1 buffer))
           (let ((free (min size (free-after-r1 buffer)))
                 (start (+ (mixed:buffer-r1-start buffer) (mixed:buffer-r1-size buffer))))
             (setf (mixed:buffer-reserved-size buffer) free)
             (setf (mixed:buffer-reserved-start buffer) start)
             (values start (+ start free))))
          (T
           (let ((free (min size (mixed:buffer-r1-start buffer))))
             (values (setf (mixed:buffer-reserved-start buffer) 0)
                     free))))))

(defun finish-write (buffer size)
  (declare (optimize speed))
  (let ((buffer (handle buffer)))
    (when (< size (mixed:buffer-reserved-size buffer))
      (error "Cannot commit more than was allocated."))
    (cond ((= 0 size))
          ((and (= 0 (mixed:buffer-r1-size buffer))
                (= 0 (mixed:buffer-r2-size buffer)))
           (setf (mixed:buffer-r1-start buffer) (mixed:buffer-r2-start buffer))
           (setf (mixed:buffer-r1-size buffer) size))
          ((= (mixed:buffer-reserved-start buffer) (+ (mixed:buffer-r1-start buffer) (mixed:buffer-r1-size buffer)))
           (incf (mixed:buffer-r1-size buffer) size))
          (T
           (incf (mixed:buffer-r2-size buffer) size)))
    (setf (mixed:buffer-reserved-size buffer) 0)
    (setf (mixed:buffer-reserved-start buffer) 0)))

(defun request-read (buffer size)
  (declare (optimize speed))
  (let ((buffer (handle buffer)))
    (values (mixed:buffer-r1-start buffer)
            (min size (mixed:buffer-r1-size buffer)))))

(defun finish-read (buffer size)
  (declare (optimize speed))
  (let ((buffer (handle buffer)))
    (when (< (mixed:buffer-r1-size buffer) size)
      (error "Cannot commit more than was available."))
    (cond ((= (mixed:buffer-r1-size buffer) size)
           (shiftf (mixed:buffer-r1-start buffer) (mixed:buffer-r2-start) 0)
           (shiftf (mixed:buffer-r1-size buffer) (mixed:buffer-r2-size) 0))
          (T
           (decf (mixed:buffer-r1-size buffer) size)
           (incf (mixed:buffer-r1-start buffer) size)))))

(defmacro with-buffer-tx ((data start end buffer &key (direction :read) (size #xFFFFFFFF)) &body body)
  (let ((bufferg (gensym "BUFFER"))
        (sizeg (gensym "SIZE"))
        (handle (gensym "HANDLE")))
    `(let* ((,bufferg ,buffer)
            (,data (data ,bufferg)))
       (ecase ,direction
         (:read
          (multiple-value-bind (,start ,end) (request-read ,bufferg ,size)
            (flet ((finish (,sizeg) (finish-read ,bufferg ,sizeg)))
              ,@body)))
         (:write
          (multiple-value-bind (,start ,end) (request-write ,bufferg ,size)
            (flet ((finish (,sizeg) (finish-write ,bufferg ,sizeg)))
              (unwind-protect
                   (progn ,@body)
                (let ((,handle (handle ,buffer)))
                  (setf (mixed:buffer-reserved-size ,handle) 0)
                  (setf (mixed:buffer-reserved-start ,handle) 0))))))))))

(defmacro with-buffer-transfer ((fdata fstart fend from &optional (size #xFFFFFFFF)) (tdata tstart tend to) &body body)
  `(let* ((,fromg ,from)
          (,tog ,to))
     (if (eq ,fromg ,tog)
         (multiple-value-bind (,fstart ,fend) (request-read ,fromg ,size)
           (let* ((,tstart ,fstart) (,tend ,fend)
                  (,fdata (data ,fromg)) (,tdata ,fdata))
             ,@body))
         (with-buffer-tx (,fdata ,fstart ,fend ,fromg :direction :read :size ,size)
           (with-buffer-tx (,tdata ,tstart ,tend ,tog :direction :write :size (min (- ,fend ,fstart) ,size))
             ,@body)))))
