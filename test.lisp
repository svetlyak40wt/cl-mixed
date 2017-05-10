(ql:quickload '(cl-mixed cl-out123 cl-mpg123))

(defmacro with-edge-setup ((file out samplerate &key pathname samples) &body body)
  `(call-with-edge-setup (lambda (,file ,out ,samplerate) ,@body) ,pathname ,samples))

(defun call-with-edge-setup (function pathname samples)
  (let* ((file (cl-mpg123:connect (cl-mpg123:make-file pathname :buffer-size NIL)))
         (out  (cl-out123:connect (cl-out123:make-output NIL)))
         (samplerate 0))
    (format T "~&Playback device ~a / ~a" (cl-out123:driver out) (cl-out123:device out))
    (multiple-value-bind (rate channels encoding) (cl-mpg123:file-format file)
      (format T "~&Input format ~a Hz ~a channels ~a encoded." rate channels encoding)
      (setf samplerate rate)
      (setf (cl-mpg123:buffer-size file) (* samples channels (cl-mixed:samplesize encoding)))
      (setf (cl-mpg123:buffer file) (cffi:foreign-alloc :uchar :count (cl-mpg123:buffer-size file)))
      (cl-out123:start out :rate rate :channels channels :encoding encoding))
    (unwind-protect
         (funcall function file out samplerate)
      (cl-out123:stop out)
      (cl-out123:disconnect out)
      (cl-mpg123:disconnect file)
      (cffi:foreign-free (cl-mpg123:buffer file)))))

(defun play (file out mixer samples)
  (let* ((buffer (cl-mpg123:buffer file))
         (buffersize (cl-mpg123:buffer-size file))
         (read (cl-mpg123:process file)))
    (loop for i from read below buffersize
          do (setf (cffi:mem-aref buffer :uchar i) 0))
    (cl-mixed:mix samples mixer)
    (let ((played (cl-out123:play out buffer buffersize)))
      (when (/= played read)
        (format T "~&Playback is not catching up with input by ~a bytes."
                (- read played))))
    (/= 0 read)))

(defun test-space (mp3 &key (samples 500) (width 100) (height 50) (speed 0.001))
  (with-edge-setup (file out samplerate :pathname mp3 :samples samples)
    (let* ((source (cl-mixed:make-source (cl-mpg123:buffer file)
                                         (cl-mpg123:buffer-size file)
                                         (cl-mpg123:encoding file)
                                         (cl-mpg123:channels file)
                                         :alternating
                                         samplerate))
           (drain (cl-mixed:make-drain (cl-mpg123:buffer file)
                                       (cl-mpg123:buffer-size file)
                                       (cl-out123:encoding out)
                                       (cl-out123:channels out)
                                       :alternating
                                       samplerate))
           (space (make-instance 'cl-mixed:space :samplerate samplerate))
           (mixer (cl-mixed:make-mixer source space drain)))
      (cl-mixed:with-buffers samples (li ri lo ro)
        (cl-mixed:connect source :left space 0 li)
        (setf (cl-mixed:output :right source) ri)
        (cl-mixed:connect space :left drain :left lo)
        (cl-mixed:connect space :right drain :right ro)
        (cl-mixed:start mixer)
        (unwind-protect
             (loop for tt = 0 then (+ tt speed)
                   for dx = 0 then (- (* width (sin tt)) x)
                   for dz = 0 then (- (* height (cos tt)) z)
                   for x = (* width (sin tt)) then (+ x dx)
                   for z = (* height (cos tt)) then (+ z dz)
                   do (setf (cl-mixed:input-field :location 0 space) (list x 0 z))
                      (setf (cl-mixed:input-field :velocity 0 space) (list dx 0 dz))
                   while (play file out mixer samples))
          (cl-mixed:end mixer))))))
