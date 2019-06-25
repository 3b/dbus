;;;; +----------------------------------------------------------------+
;;;; | DBUS                                                           |
;;;; +----------------------------------------------------------------+

(defpackage #:dbus/connections
  (:use #:cl
        #:dbus/utils #:dbus/protocols #:dbus/authentication-mechanisms
        #:dbus/messages #:dbus/conditions)
  (:import-from #:alexandria #:ensure-list #:deletef)
  (:import-from #:iolib #:event-dispatch #:set-io-handler #:make-socket
                #:connect #:fd-of)
  (:export
   #:with-open-connection
   #:standard-connection
   #:socket-connection-mixin
   #:open-socket-connection
   #:connection-event-base))

(in-package #:dbus/connections)


;;;; Connections

(defmacro with-open-connection ((connection event-base server-addresses &key (if-failed :error)) &body forms)
  `(let ((,connection (open-connection ,event-base ,server-addresses :if-failed ,if-failed)))
     (unwind-protect
          (progn ,@forms)
       (when ,connection
         (close-connection ,connection)))))

(defclass standard-connection (connection)
  ((server-address :initarg :server-address :reader connection-server-address)
   (uuid :initarg :uuid :accessor connection-server-uuid)
   (pending-messages :initform '() :accessor connection-pending-messages)
   (event-base :initarg :event-base :reader connection-event-base)
   (serial :initform 1)
   (supports-unix-fd-passing :initform nil :accessor supports-unix-fd-passing-p))
  (:default-initargs :uuid nil)
  (:documentation "Represents a standard DBUS connection."))

(defmethod (setf connection-server-uuid) :before (new-uuid (connection standard-connection))
  (let ((old-uuid (connection-server-uuid connection)))
    (when (and old-uuid (not (equal old-uuid new-uuid)))
      (cerror "Set new ID and continue."
              "A server ID is already assigned to this connection."))))

(defmethod connection-next-serial ((connection standard-connection))
  (with-slots (serial) connection
    (prog1 serial
      (setf serial
            (let ((x (logand (1+ serial) #xFFFFFFFF)))
              (if (zerop x) 1 x))))))

(defmethod drain-pending-messages ((connection standard-connection))
  (prog1 (nreverse (connection-pending-messages connection))
    (setf (connection-pending-messages connection) '())))

(defmethod wait-for-reply (serial (connection standard-connection))
  (loop
   (dolist (message (connection-pending-messages connection))
     (when (and (typep message '(or error-message method-return-message))
                (= serial (message-reply-serial message)))
       (deletef (connection-pending-messages connection) message :count 1)
       (return-from wait-for-reply
         (values (message-body message) message))))
   (event-dispatch (connection-event-base connection) :one-shot t)))

(defun activate-io-handlers (connection)
  (set-io-handler
   (connection-event-base connection)
   (connection-fd connection)
   :read
   (lambda (fd event error)
     (declare (ignore fd event))
     (when error
       (error "Connection I/O error: ~S." error))
     (loop for message = (receive-message-no-hang connection)
           while message
           do (push message (connection-pending-messages connection))))))

(defmethod supported-authentication-mechanisms ((connection standard-connection))
  (send-authentication-command connection :auth)
  (mapcar (lambda (name)
            (make-instance
             (or (find-authentication-mechanism-class name :if-does-not-exist nil)
                 'generic-authentication-mechanism)
             :name name))
          (receive-authentication-response connection :expect :rejected)))

(defmethod authenticate :around (mechanisms (connection standard-connection) &key (if-failed :error))
  (with-if-failed-handler if-failed
    (when (call-next-method)
      (activate-io-handlers connection)
      t)))

(defmethod authenticate (mechanisms (connection standard-connection) &key (if-failed :error))
  (declare (ignore if-failed))
  (setf mechanisms (ensure-list mechanisms))
  (let (op arg mechanism)
    (flet ((send (command &rest args)
             (apply #'send-authentication-command connection command args))
           (receive ()
             (receive-authentication-response connection :as-string (authentication-mechanism-textual-p mechanism))))
      (tagbody
       initial
         (if (null mechanisms)
             (error "No more mechanisms to try.")
             (setf mechanism (pop mechanisms)))
         (multiple-value-setq (op arg) (feed-authentication-mechanism mechanism :initial-response))
         (when (eq op :error)
           (go initial))
         (send :auth (authentication-mechanism-name mechanism) arg)
         (ecase op
           (:ok (go waiting-for-ok))
           (:continue (go waiting-for-data)))
       waiting-for-data
         (multiple-value-setq (op arg) (receive))
         (case op
           (:data
            (multiple-value-setq (op arg) (feed-authentication-mechanism mechanism arg))
            (ecase op
              (:continue (send :data arg) (go waiting-for-data))
              (:ok (send :data arg) (go waiting-for-ok))
              (:error (if arg (send :error arg) (send :error)) (go waiting-for-data))))
           (:rejected (go initial))
           (:error (send :cancel) (go waiting-for-reject))
           (:ok (go got-ok))
           (t (send :error) (go waiting-for-data)))
       waiting-for-ok
         (multiple-value-setq (op arg) (receive))
         (case op
           (:ok (go got-ok))
           (:reject (go initial))
           ((:data :error) (send :cancel) (go waiting-for-reject))
           (t (send :error) (go waiting-for-ok)))
       waiting-for-reject
         (multiple-value-setq (op arg) (receive))
         (case op
           (:reject (go initial))
           (t (error 'authentication-error :command op :argument arg)))
       got-ok
         (setf (connection-server-uuid connection) arg)
         (send :negotiate-unix-fd)
         (go wait-for-unix-fd-passing-agreement)
       wait-for-unix-fd-passing-agreement
         (multiple-value-setq (op arg) (receive))
         (case op
           (:error
            (setf (supports-unix-fd-passing-p connection) nil))
           (:agree-unix-fd
            (setf (supports-unix-fd-passing-p connection) t))
           (t (error 'authentication-error :command op :argument arg)))
         (send :begin)
         (go authenticated)
       authenticated)))
  t)


;;;; Socket-based connection mixin

(defclass socket-connection-mixin ()
  ((socket :initarg :socket :reader connection-socket)))

(defun open-socket-connection (address-family socket-address)
  (let ((socket (make-socket :address-family address-family
                             :external-format '(:utf-8 :eol-style :crlf))))
    (setf (iolib/streams::read-fn-of socket)
          #'read-with-fds)
    (unwind-protect
         (progn
           (connect socket socket-address)
           (write-byte 0 socket)
           (force-output socket)
           (prog1 socket
             (setf socket nil)))
      (when socket
        (close socket)))))

(defmethod connection-fd ((connection socket-connection-mixin))
  (fd-of (connection-socket connection)))

(defmethod close-connection ((connection socket-connection-mixin))
  (close (connection-socket connection)))

(defmethod receive-message-no-hang ((connection socket-connection-mixin))
  (decode-message (connection-socket connection)))

(defmethod receive-line ((connection socket-connection-mixin))
  (read-line (connection-socket connection)))

(defmethod send-line (line (connection socket-connection-mixin))
  (write-line line (connection-socket connection))
  (force-output (connection-socket connection)))

(defmethod send-message (encoded-message (connection socket-connection-mixin))
  (write-sequence encoded-message (connection-socket connection))
  (force-output (connection-socket connection)))
