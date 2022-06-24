(in-package :loopus.ir)

;; First, some variable. Lot of them
;; Then, the code

;; To create points on the domain side
(defvar *size-domain*)
;; Needs to be even. 2 per loop variable
(defvar *space-domain*)

;; To create points on the range side
(defvar *size-range*)
;; A[i, j] consumes 3 spot (1 for the array, 1 for i, 1 for j)
(defvar *space-range*)

;; The space of maps (domain -> range)
(defvar *space-map-domain-range*)

;; The space of schedule (domain -> domain)
(defvar *space-map-schedule*)

;; How many free variable we can have
(defvar *size-free-parameters*)

;; Add parameters from free variables
;; Position can be found with the hashtable
(defvar *free-variable-to-index*)

;; hashtable of ir-construct-node to position of the identifier
(defvar *construct-to-identifier*) ;; ir-construct-node to position (integer)
(defvar position-next-free-variable) ;; at first it's *size-domain*. Gets incf each time

;; Definition of variables that will hold the set/map of domain/read/write/schedule
(defvar *set-domain*)
(defvar *map-read*)
(defvar *map-write*)
(defvar *map-schedule*)

;; Modify a map to add it another map (union of both) (same for push-set)
(defmacro push-map (map object)
  `(setf ,map (isl:union-map-union ,map ,object)))
(defmacro push-set (set object)
  `(setf ,set (isl:union-set-union ,set ,object)))

;; Generate an unique number for each ir-node
(defvar *counter-range*) ; the value they'll have. It's just increment by 1 each time
(defvar *all-irnodes*) ; the map ir-node -> int (this unique value)
(defun uniquenumber (producer)
  (let ((v (if ; todo refactor ?
            (ir-construct-p producer)
            (ir-construct-form producer)
            producer)))
    (values
     (alexandria:ensure-gethash v *all-irnodes* (incf *counter-range*)))))

;; List of all loop-variables of loops we are currently in
(defvar *loop-variables*)
(defun is-loop-variable (node)
  (position node *loop-variables*))

;; List of loop bounds
(defvar *loop-bounds*)


;;;;;;;;;;;;;;;
;; DOMAIN
;;;;;;;;;;;;;;;

;; We want to create the set [*counter*1, loop-var1, *counter*2, loop-var2, ...] : start <= loop-var1 < end; start <= ...
;; We start from universe { [*, *] }
;; Add constraint for each loop-var to have { [*counter*, loop-var] : start <= loop-var < end }
;; The function that does what is described just above is create-new-point-domain, 2 s-expr below


;; Add a constant value to the constraint. Can be a known value or a variable
(defun add-constant-constraint (constraint value i delta)
  ;; 3 cases:
  ;; + integer -> just add the value
  ;; + loop variable -> *loop-variables* has the first value the most inner loop so we need to reverse it
  ;; + free variable -> pick from *construct-to-identifier*

  ;; Delta is here because constraints on isl are <=, and loopus it's <
  (if (integerp value)
      ;; integer
      (isl:inequality-constraint-set-constant constraint (isl:value (+ delta (* i value))))
      (let ((idx-loop-variable (position value *loop-variables*)))
        (if idx-loop-variable
            ;; loop variable
            (isl:inequality-constraint-set-coefficient
             (isl:inequality-constraint-set-constant constraint (isl:value delta)) ; Add the -1 constant in the inequality
             :dim-set (1+ idx-loop-variable)
             (isl:value i))
            (let ((idx-free-variable
                    (alexandria:ensure-gethash ; position-next-free-variable is incremented only when not found
                     (ir-construct-form (ir-value-producer value))
                     *construct-to-identifier*
                     (incf position-next-free-variable))))
              (if idx-free-variable
                  ;; free variable
                    (isl:inequality-constraint-set-coefficient
                     (isl:inequality-constraint-set-constant constraint (isl:value delta))
                     :dim-param idx-free-variable
                     (isl:value i))
                  (break "can't happen")))))))

(defvar *counter-domain*) ; List of counters
(defvar *global-counter*) ; Global counter to rememeber which is what instruction
(defun create-new-point-domain ()
  ;; The structure we want to have: see commentary above. Start from universe, and create each part
  (let* ((result (isl:basic-set-universe *space-domain*))
         (local-space-domain (isl:local-space-from-space *space-domain*)))
    ;; Part for each loop var
    (loop for p below (* 2 *current-depth*) by 2 do
      ;; First, the creation of the global counter, and then the loop variable
      (let* (;; Creation of the counter
             (constraint (isl:make-equality-constraint local-space-domain))
             (constraint (isl:equality-constraint-set-constant constraint (isl:value (nth (/ p 2) *counter-domain*))))
             (constraint (isl:equality-constraint-set-coefficient constraint :dim-set p (isl:value -1)))
             (_ (setf result (isl:basic-set-add-constraint result constraint)))
             ;; Creation of the variable
             (bounds (nth (/ p 2) (reverse *loop-bounds*)))
             (p (1+ p))
             ;; The variable at the very left is the outer loop, so it's the good order
             (start-value (first bounds))
             (end-value (second bounds))
             (step-value (third bounds))
             (inputs (nth 3 bounds))
             ;; Creation of the step
             (aff (isl:create-var-affine local-space-domain :dim-set p))
             ;; todo general case
             ;;(_ (assert (integerp start-value)))
             ;; if step is not known, the loop direction is unknown, and not sure what I should do
             ;; but the user probably know the loop direction anyway, maybe better to ask him
             (_ (assert (integerp step-value)))
             (aff (isl:affine-mul aff (isl:create-val-affine local-space-domain (isl:value step-value))))
             (aff (isl:affine-add aff (affine-expression-from-loopus-ast (first inputs) local-space-domain)))
             (affmap (isl:basic-map-from-affine aff))
             (_ (ins affmap))
             (affmap (isl:basic-map-insert-dimension affmap :dim-out 0 p))
             ;; size domain or current depth?
             (affmap (isl:basic-map-insert-dimension affmap :dim-out (1+ p) (- (1- *size-domain*) p)))
             (_ (ins affmap))
             (_ (setf result (isl:basic-set-intersect result (isl::basic-set-apply result affmap))))
             ;; Creation of [*, i] : start <= i
             (constraint (isl:make-inequality-constraint local-space-domain))
             (constraint (add-constant-constraint constraint start-value -1 0))
             (constraint (isl:inequality-constraint-set-coefficient constraint :dim-set p (isl:value 1)))
             (_ (setf result (isl:basic-set-add-constraint result constraint)))
             (_ (ins result))
             ;; Creation of [*, i] : start <= i < end
             (constraint (isl:make-inequality-constraint local-space-domain))
             (constraint (add-constant-constraint constraint end-value 1 -1))
             (constraint (isl:inequality-constraint-set-coefficient constraint :dim-set p (isl:value -1)))
             (_ (setf result (isl:basic-set-add-constraint result constraint)))
             ;(_ (ins affmap))
             ;(_ (ins result))
             ;(_ (ins "apply"))
             ;(_ (ins (isl::basic-set-apply result affmap)))
             ;(_ (isl::basic-map-intersect-range affmap result))
             ;; The "<" comes from the -1 in add-constant-constraint. We actually create i <= end - 1
             ;; End of this iteration: [*counter-domain*, i for one more variable] : start <= i < end
             ;; Todo check if we can refactor the 2 comments above
             )))
    ;; Last counter
    (let* ((constraint (isl:make-equality-constraint local-space-domain))
           (constraint (isl:equality-constraint-set-constant constraint (isl:value *global-counter*)))
           (constraint (isl:equality-constraint-set-coefficient constraint :dim-set (* 2 *current-depth*) (isl:value -1)))
           (_ (setf result (isl:basic-set-add-constraint result constraint))))
      ;; Now we have [*counter-domain*, i, ...]
      ;; Part to fill the rest
      (loop for p from (1+ (* 2 *current-depth*)) below *size-domain* do
        (let* ((constraint (isl:make-equality-constraint local-space-domain))
               (constraint (isl:equality-constraint-set-constant constraint (isl:value -1)))
               (constraint (isl:equality-constraint-set-coefficient constraint :dim-set p (isl:value -1)))
               (_ (setf result (isl:basic-set-add-constraint result constraint))))))
      ;; Now we have what we wanted
      (isl:basic-set-union-set result))))

;; todo 0 i 0 j 0 instead of 0 i 0 j


;;;;;;;;;;;;;;;
;; READ/WRITE
;;;;;;;;;;;;;;;

;; This will get called on each instruction that can read or write

;; First, create the affine expression
;; Todo merge this with add-constant-constraint
(defun affine-expression-from-loopus-ast (ast local-space)
  ;; maybe ir-if
  ;; todo generic function
  ;; If it's a call, we do a recursive call to ourself :-)
  (if (ir-call-p (ir-value-producer ast))
      (let* ((the-call (ir-value-producer ast))
             (a (first (ir-node-inputs the-call)))
             (b (second (ir-node-inputs the-call)))
             ;; We call recursively on a and b. "this" is the current function
             (this (lambda (arg) (affine-expression-from-loopus-ast arg local-space)))
             (new-a (funcall this a))
             (new-b (funcall this b)))
        ;; If one of the expression isn't recognized, we are not recognized too
        (if (not (and new-a new-b))
            nil
            ;; integer+ integer- integer* takes 2 arguments due to typo
            ;; todo generalize by checking if types and number of arguments are ok to do the thing below
            (case (typo:fnrecord-name (ir-call-fnrecord the-call))
              (typo:integer+ (isl:affine-add new-a new-b))
              (typo:integer- (isl:affine-sub new-a new-b))
              (typo:integer* (isl:affine-mul new-a new-b))
              ;; otherwise universe set todo
              ;; todo rationnal
              #+or(typo:integer/ (isl:affine-div new-a new-b))
              (otherwise
               ;; Otherwise, we don't know/recognize what it is. Return the universe
               nil))))
        ;; Otherwise, base case
      (let ((pos-variable (is-loop-variable ast)))
        (if pos-variable
            ;; Loop variable
            (isl:create-var-affine local-space :dim-set (1+ (* 2 pos-variable)))
            (let ((idx-free-variable
                    (alexandria:ensure-gethash
                     (ir-construct-form (ir-value-producer ast))
                     *construct-to-identifier*
                     (incf position-next-free-variable))))
              (if idx-free-variable
                  ;; Free variable
                  (isl:create-var-affine local-space :dim-param idx-free-variable)
                  ;; Generic construct form
                  (isl:create-val-affine local-space (isl:value (second (ir-value-derived-type ast))))))))))

(defun get-value (node)
  (let* ((producer (ir-value-producer node)))
    (uniquenumber producer)))
(defun create-new-point-range-new (&rest args)
  ;; Creation of the result map, and adding the constraint of the array
  (let* ((result (isl:basic-map-universe *space-map-domain-range*))
         (local-space (isl:local-space-from-space *space-map-domain-range*))
         (local-space-domain (isl:local-space-from-space *space-domain*))
         (constraint (isl:make-equality-constraint local-space))
         (constraint (isl:equality-constraint-set-constant constraint (isl:value (get-value (first args)))))
         (constraint (isl:equality-constraint-set-coefficient constraint :dim-out 0 (isl:value -1)))
         (result (isl:basic-map-add-constraint result constraint)))
    ;; The, we do all arguments of the read. So if (aref a b c 1 3) we do for a b c 1 3
    (loop for idx from 1 below (length args) do
      ;; For everything we read, we create an affixe expression of what it is, and create the associated map
      (let* ((affine-expression (affine-expression-from-loopus-ast (nth idx args) local-space-domain))
             (new-map (if affine-expression
                          (isl:basic-map-from-affine affine-expression)
                          (isl:basic-map-universe *space-map-domain-range*)))
             ;; The map we just created is [o0, o1, ...] -> [our expression]
             ;; (Unless affine-expression is nil (not recognized), and then we already have the good map)
             ;; We need to extend the range to obtain [o0, o1, ...] -> [i0, our expression, ...]
             ;; We add first everything before; then everything after
             ;; idx here is (+ 1 (1- idx)) ; 1 is for the array, (1- idx) is the every loop variable before
             (_ (when affine-expression
                  (setf new-map (isl:basic-map-insert-dimension new-map :dim-out 0 idx))))
             ;; About 0, and (1+ idx). It's the insertion position.
             ;; The final result we want is [smth, our expression, smth]
             ;; So first, we insert before, hence the 0
             ;; Then, we insert just after, hence (1+ idx). We inserted idx elements, so we have (1+ idx) total elements
             (_ (when affine-expression
                  (setf new-map (isl:basic-map-insert-dimension new-map :dim-out (1+ idx) (- *size-range* (1+ idx)))))))
        (setf result (isl:basic-map-intersect result new-map))))
    ;; Fill for the rest with a single value
    (loop for p from (length args) below *size-range* do
      (let* ((constraint (isl:make-equality-constraint local-space))
             (constraint (isl:equality-constraint-set-constant constraint (isl:value -1)))
             (constraint (isl:equality-constraint-set-coefficient constraint :dim-out p (isl:value -1))))
        (setf result (isl:basic-map-add-constraint result constraint))))
    result))


;; Old version
#+or(defun create-new-point-range (&rest args)
  (let* ((result (isl:basic-map-universe *space-map-domain-range*))
         (*space-map-domain-range* (isl:local-space-from-space *space-map-domain-range*))
         (bot (isl:make-equality-constraint *space-map-domain-range*)))
    ;; First the array
    (setf bot (isl:equality-constraint-set-constant bot (isl:value (get-value (first args)))))
    (setf bot (isl:equality-constraint-set-coefficient bot :dim-out 0 (isl:value -1)))
    (setf result (isl:basic-map-add-constraint result bot))
    ;; We do all arguments of the read. So if (aref a b c 1 3) we do for a b c 1 3
    (loop for idx from 1 below (length args) do
      (let ((pos-variable (is-loop-variable (nth idx args)))
            (bot (isl:make-equality-constraint *space-map-domain-range*)))
        (if pos-variable
            ;; If we are a loop variable
            (progn
              (setf bot (isl:equality-constraint-set-coefficient bot :dim-in (- (- (length args) 1) pos-variable) (isl:value -1)))
              (setf bot (isl:equality-constraint-set-coefficient bot :dim-out idx (isl:value 1))))
            ;; Otherwise, we are a constant (or more but todo)
            (progn
              ;; Parse the value it has
              (let ((value (second (ir-value-declared-type (nth idx args)))))
                (setf bot (isl:equality-constraint-set-constant bot (isl:value value)))
                (setf bot (isl:equality-constraint-set-coefficient bot :dim-out idx (isl:value -1))))))
        (setf result (isl:basic-map-add-constraint result bot))))
    ;; Fill for the rest with a single value
    (loop for p from (length args) below *size-range* do
          (let* ((bot (isl:make-equality-constraint *space-map-domain-range*))
                 (bot (isl:equality-constraint-set-constant bot (isl:value -1)))
                 (bot (isl:equality-constraint-set-coefficient bot :dim-out p (isl:value -1)))
                 (_ (setf result (isl:basic-map-add-constraint result bot))))))
    result))

;;;;;;;;;;;;;;;
;; SCHEDULE
;;;;;;;;;;;;;;;

(defun create-map-schedule (timestamp)
  (isl:union-set-identity timestamp))

;; Old version
;; I'm a clown and it's just (identity domain domain) ?
#+or(defun create-map-schedule (&rest args)
  (let* ((result (isl:basic-map-universe *space-map-schedule*))
         (*space-map-schedule* (isl:local-space-from-space *space-map-schedule*))
         (bot (isl:make-equality-constraint *space-map-schedule*))
         (bot (isl:equality-constraint-set-constant bot (isl:value *counter-domain*)))
         (bot (isl:equality-constraint-set-coefficient bot :dim-in 0 (isl:value -1)))
         (result (isl:basic-map-add-constraint result bot))
         (bot (isl:make-equality-constraint *space-map-schedule*))
         (bot (isl:equality-constraint-set-constant bot (isl:value *counter-domain*)))
         (bot (isl:equality-constraint-set-coefficient bot :dim-out 0 (isl:value -1)))
         (result (isl:basic-map-add-constraint result bot)))
    ;; Loop for each variable
    (loop for idx from 0 below *current-depth* do
      ;; Now, for each loop variable, we map it to the correct left part
      (let* ((bot (isl:make-equality-constraint *space-map-schedule*))
             (pos-variable (is-loop-variable (nth idx (first args))))
             (bot (isl:equality-constraint-set-coefficient
                   bot
                   :dim-in (+ 1 pos-variable)
                   (isl:value -1)))
             (bot (isl:equality-constraint-set-coefficient
                   bot
                   :dim-out (1+ idx)
                   (isl:value 1)))
             (_ (setf result (isl:basic-map-add-constraint result bot))))))
    ;; Loop for the rest
    (loop for idx from *current-depth* below *size-domain* do
      (let* ((bot (isl:make-equality-constraint *space-map-schedule*))
             (bot (isl:equality-constraint-set-coefficient
                   bot
                   :dim-in idx
                   (isl:value -1)))
             (bot (isl:equality-constraint-set-coefficient
                   bot
                   :dim-out idx
                   (isl:value 1)))
             (_ (setf result (isl:basic-map-add-constraint result bot))))))
    (isl:basic-map-union-map result)))



;; Function that'll be mapped on all ir nodes
(defgeneric update-node (node))
(defmethod update-node ((node ir-node)))

(defmacro my-incf (v)
  `(setf ,v (* (+ 1 ,v) 2)))
(defvar *id-to-expression*) ; int -> loopus node
(defvar *depth-node*) ; loopus for node -> depth
(defvar *current-depth*)


;; Function call
;; Right now, only check if it's aref/setf, otherwise it does nothing
(defmethod update-node ((node ir-call))
  (let* ((function-call node)
         (args (ir-node-inputs node))
         (is-aref (eql 'aref (typo:fnrecord-name (ir-call-fnrecord node))))
         (is-setf (equal '(setf aref) (typo:fnrecord-name (ir-call-fnrecord node))))
         (current-timestamp (create-new-point-domain)))
    ;; Current timestamp is the set of timestamp corresponding to this single instruction
    ;; If it's a instructon outisde a loop, the set will only have a single element
    ;; Otherwise if it's in a "i" loop, it'd be for instance { [0, i]: start <= i < end }
    ;; For each point of this set, a read/write operation is maybe performed
    ;; We want to add to *map-read/write* the map, for instance, { [0, i] -> A[i, 0] } if A[i, 0] is read
    ;; Will become (when (or "map read can be modified" "map write can be modified"))
    (when (or is-aref is-setf)
      ;; Add the loopus node to the hashtable
      (setf (gethash *global-counter* *id-to-expression*) node)
      ;; Add to *set-domain*
      (push-set *set-domain* current-timestamp)
      ;; Add to *map-read* and/or *map-write*
      ;;todo refactor
      (let* ((what-is-read/wrote-in-order
               (if is-aref
                   ;; If it's an aref, just gives what follows aref
                   ;; (aref a b c d e) -> args will be (a b c d e)
                   (cons (first args) (reverse (cdr args)))
                   ;; If it's an setf, it's ((setf aref) value a b c d e)
                   ;; instead of (aref a b c d e) like above
                   ;; So (cdr args) is (a b c d e)
                   (cons (first (cdr args)) (reverse (cddr args)))
                   ))
             ;; Old version
             ;;(map-of-read/write (apply #'create-new-point-range what-is-read/wrote-in-order))
             ;;(map-of-read/write (isl:basic-map-union-map map-of-read/write))
             ;;(map-of-read/write (isl:union-map-intersect-domain map-of-read/write current-timestamp))
             ;; End of old version
             (map-of-read/write (isl:basic-map-union-map (apply #'create-new-point-range-new what-is-read/wrote-in-order)))
             (map-of-read/write (isl:union-map-intersect-domain map-of-read/write current-timestamp)))
        (when is-aref (push-map *map-read* map-of-read/write))
        (when is-setf (push-map *map-write* map-of-read/write)))
      ;; Add to *map-schedule*
      (push-map *map-schedule* (create-map-schedule current-timestamp))
      #+or(isl:union-map-intersect-domain
           (create-map-schedule *loop-variables*)
           current-timestamp)
      (my-incf *global-counter*))))

;; todo
(defun parse-bound (value)
  (if (typo.ntype:eql-ntype-p (ir-value-derived-ntype value))
      ;(typo:eql-ntype-object
      (second (ir-value-derived-type value))
      value)) ;;todo
;;      (ir-construct-form (ir-value-producer value))))

(defun parse-end-bound (value variable)
  ;; We only do something (now) when the loop is know
  ;; otherwise todo loop end is a free variable
  (assert (= (length (ir-node-inputs value)) 1))
  ;; otherwise, the return value is the node just before the final node
  (let* ((boolean (typo:eql-ntype-object (ir-value-derived-ntype (first (ir-node-inputs value)))))
         (branch-taken (if boolean (ir-then value) (ir-if-else value)))
         (ir-call (ir-node-predecessor (ir-final-node branch-taken)))
         ;; ..................
         (ir-call (ir-value-producer (second (ir-node-inputs ir-call))))
         (_ (assert (= 2 (length (ir-node-inputs ir-call)))))
         (f (typo:fnrecord-name (ir-call-fnrecord ir-call)))
         (a (first (ir-node-inputs ir-call)))
         (b (second (ir-node-inputs ir-call))))
    (cond
      ((and (eql a variable) (eql f '<)) (parse-bound b))
      ((and (eql a variable) (eql f '<=)) (parse-bound (1+ b)))
      ;; a > variable --> the end is a
      ((and (eql b variable) (eql f '>)) (parse-bound a))
      ((and (eql b variable) (eql f '>=)) (parse-bound (1+ a)))
      (t (break "We cannot optimize this loop for now")))))

;; Todo handle lexical scope
(defmethod update-node ((node ir-loop))
  ;; First, we add informations (the current loop variable, the depth, etc...)
  ;; And then, last s-expr, call recursively on the body of the loop!
  ;; List of loop variables
  (let* ((*loop-variables* (append *loop-variables* (list (ir-loop-variable node))))
         ;; Current depth we are in
         (_ (setf (gethash node *depth-node*) *current-depth*))
         (*current-depth* (1+ *current-depth*))
         (*counter-domain* (append *counter-domain* (list *global-counter*)))
         ;; Loop bounds
         (inputs (ir-node-inputs node))
         (start (parse-bound (first inputs)))
         (step (parse-bound (second inputs)))
         (end (parse-end-bound
               (ir-node-predecessor (ir-final-node (ir-loop-test node)))
               (ir-loop-variable node)))
         ;; todo step too ?
         (*loop-bounds* (cons (list start end step inputs) *loop-bounds*)))
    ;; Recursive call
    (map-block-inner-nodes #'update-node (ir-loop-body node))
    ;; No need to restore the hashtable, every node is different ?
    ;; Also it's used in the output part
    ;;(remhash node *depth-node*)
    ))
