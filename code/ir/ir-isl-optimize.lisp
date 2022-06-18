(in-package #:loopus.ir)

;; todo if ?


;; Max loop depth
(defmethod map-tree-inner-nodes (_ (ir ir-node) (context (eql 'depth))) 0)
(defmethod map-tree-inner-nodes (_ (ir ir-loop) (context (eql 'depth)))
  (1+ (call-next-method)))

;; Max array dimension
(defmethod map-tree-inner-nodes (_ (ir ir-node) (context (eql 'arraydimension)))
  0)
(defmethod max-tree-inner-nodes (_ (ir ir-call) (context (eql 'arraydimension)))
  (let ((args (ir-node-inputs ir))
        (is-aref (eql 'aref (typo:fnrecord-name (ir-call-fnrecord ir))))
        (is-setf (equal '(setf aref) (typo:fnrecord-name (ir-call-fnrecord ir)))))
    (cond
      ;; args is either (aref array idx...) or ((setf aref) value array idx...)
      (is-aref (length (cdr args))) ; it's (aref array idx1 idx2 ...)
      (is-setf (length (cddr args))) ; it's ((setf aref) value array idx1 idx2), hence cddr
      (t 0))))

;; Free parameters
(defmethod map-tree-inner-nodes (_ (ir ir-node) (context (eql 'free-parameters))) 0)
(defmethod map-tree-inner-nodes (_ (ir ir-construct) (context (eql 'free-parameters))) 1) ; todo better upper bound

;; Max loop depth
(defgeneric compute-max-loop-depth (ir))
(defmethod compute-max-loop-depth ((ir ir-loop))
  (1+ (compute-max-loop-depth (ir-loop-body ir))))
(defmethod compute-max-loop-depth ((ir ir-initial-node))
  (let ((value 0))
    (map-block-inner-nodes
     (lambda (ir) (setf value (max value (compute-max-loop-depth ir))))
     ir)
    value))
(defmethod compute-max-loop-depth ((ir ir-node)) 0)


;; Max dimension of array access on read/write access (print array) doesn't count
(defgeneric compute-max-array-dimension (ir))
(defmethod compute-max-array-dimension ((ir ir-loop))
  (compute-max-array-dimension (ir-loop-body ir)))
;; todo refactor this and the opdate-node on ir-call in input.lisp
(defmethod compute-max-array-dimension ((ir ir-call))
  (let ((args (ir-node-inputs ir))
        (is-aref (eql 'aref (typo:fnrecord-name (ir-call-fnrecord ir))))
        (is-setf (equal '(setf aref) (typo:fnrecord-name (ir-call-fnrecord ir)))))
    (cond
      ;; args is either (aref array idx...) or ((setf aref) value array idx...)
      (is-aref (length (cdr args))) ; it's (aref array idx1 idx2 ...)
      (is-setf (length (cddr args))) ; it's ((setf aref) value array idx1 idx2), hence cddr
      (t 0))))
(defmethod compute-max-array-dimension ((ir ir-initial-node))
  (let ((value 0))
    (map-block-inner-nodes
     (lambda (ir) (setf value (max value (compute-max-array-dimension ir))))
     ir)
    value))
(defmethod compute-max-array-dimension ((ir ir-node)) 0)


;; Max number of free variable
(defgeneric compute-max-free-variable (ir))
(defmethod compute-max-free-variable ((ir ir-loop))
  (compute-max-free-variable (ir-loop-body ir)))
(defmethod compute-max-free-variable ((ir ir-initial-node))
  (let ((value 0))
    (map-block-inner-nodes
     (lambda (ir) (setf value (+ value (compute-max-free-variable ir))))
     ir)
    value))
(defmethod compute-max-free-variable ((ir ir-construct))
  1) ; todo be 1 iif it may be free variable, 0 otherwise
(defmethod compute-max-free-variable ((ir ir-node)) 0)


(defun ir-isl-optimize (ir)
  "Returns a copy of IR where it's reordered by isl"
  ;; First, allocate the memory

  ;; To create points on the domain side
  ;; Needs to be even. 2 per loop variable
  (setf *size-domain* (* 2 (map-tree-inner-nodes #'max ir 'depth)))
  ;;(unless (= *size-domain* (* 2 (compute-max-loop-depth ir))) (break "size domain wrong"))
  (setf *size-domain* (* 2 (compute-max-loop-depth ir)))
  (ins *size-domain*)

  (setf *space-domain* (isl:create-space-set 0 *size-domain*))

  ;; To create points on the range side
  ;; A[i, j] consumes 3 spot (1 for the array, 1 for i, 1 for j)
  (setf *size-range* (1+ (map-tree-inner-nodes #'max ir 'arraydimension)))
  ;;(unless (= *size-range* (1+ (compute-max-array-dimension ir))) (break "size range wrong"))
  (setf *size-range* (1+ (compute-max-array-dimension ir)))
  (ins *size-range*)

  (setf *space-range* (isl:create-space-set 0 *size-range*))

  ;; The space of maps (domain -> range)
  (setf *space-map-domain-range* (isl:create-space-map 0 *size-domain* *size-range*))

  ;; The space of schedule (domain -> domain)
  (setf *space-map-schedule* (isl:create-space-map 0 *size-domain* *size-domain*))

  ;; How many free variable we can have
  (setf *size-free-parameters* (map-tree-inner-nodes #'+ ir 'free-parameters))
  ;;(unless (= *size-free-parameters* (compute-max-free-variable ir)) (break "size free parameter wrong"))
  (setf *size-free-parameters* (compute-max-free-variable ir))
  (ins *size-free-parameters*)

  ;; Add parameters from free variables
  ;; Position can be found with the hashtable
  (setf *free-variable-to-index* (make-hash-table :test 'equal))
  (loop for i below *size-free-parameters* do
    (let ((id (isl::make-gensym-identifier 'free-variable)))
      (setf (gethash (symbol-name (isl:identifier-name id)) *free-variable-to-index*) i)
      (setf *space-domain* (isl::space-add-param-id *space-domain* id))
      (setf *space-range* (isl::space-add-param-id *space-range* id))
      (setf *space-map-domain-range* (isl::space-add-param-id *space-map-domain-range* id))
      (setf *space-map-schedule* (isl::space-add-param-id *space-map-schedule* id))))

  ;; hashtable of ir-construct-node to position of the identifier
  (setf *construct-to-identifier* nil) ;; ir-construct-node to position (integer)
  (setf position-next-free-variable nil) ;; at first it's *size-domain*. Gets incf each time
  ;; Definition of variables that will hold the set/map of domain/read/write/schedule
  (setf *set-domain* (isl:union-set-empty *space-domain*))
  (setf *map-read* (isl:union-map-empty *space-map-domain-range*))
  (setf *map-write* (isl:union-map-empty *space-map-domain-range*))
  (setf *map-schedule* (isl:union-map-empty *space-map-schedule*))
  ;; End of allocation of memory

  ;; Special parameters
  (setf *construct-to-identifier* (make-hash-table))
  (setf position-next-free-variable -1) ; -1 because we use the return value of incf, so the first use returns 0
  (setf *counter-range* 0)
  (setf *all-irnodes* (make-hash-table))
  (setf *loop-variables* '())
  (setf *loop-bounds* '())
  (setf *counter-domain* 0)
  (setf *id-to-expression* (make-hash-table))
  (setf *depth-node* (make-hash-table))
  (setf *current-depth* 0)
  ;; End of setf special parameters
  (map-block-inner-nodes #'update-node ir)
  (print "Domain, read, write, and schedule:")
  (print *set-domain*)
  (print *map-read*)
  (print *map-write*)
  (print *map-schedule*)
  ;; Special parameters - outputs
  (setf node nil)
  (setf *ir-value-copies* (make-hash-table))
  (setf possible-loop-variables nil)
  (setf *values* '())
  (setf *depth-loop-variables* '())
  (setf *current-depth* 0)
  (setf *position-to-loopusvariable* (make-hash-table))
  (maphash (lambda (key value) (setf (gethash value *position-to-loopusvariable*) key)) *construct-to-identifier*)
  ;; End of setf special parameters
  (let ((init-node (isl::generate-debug-ast *set-domain* *map-read* *map-write* *map-schedule*))
        (node (isl:generate-optimized-ast *set-domain* *map-read* *map-write* *map-schedule*)))
    (isl:pretty-print-node init-node)
    (isl:pretty-print-node node)
    (print "ok")
    (let ((r (my-main node nil)))
      (print (ir-expand r))
      r)))

(defun ir-isl-optimize (ir) ir)
