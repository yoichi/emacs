;;; eieio-core.el --- Core implementation for eieio  -*- lexical-binding:t -*-

;; Copyright (C) 1995-1996, 1998-2015 Free Software Foundation, Inc.

;; Author: Eric M. Ludlam <zappo@gnu.org>
;; Version: 1.4
;; Keywords: OO, lisp

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; The "core" part of EIEIO is the implementation for the object
;; system (such as eieio-defclass, or eieio-defmethod) but not the
;; base classes for the object system, which are defined in EIEIO.
;;
;; See the commentary for eieio.el for more about EIEIO itself.

;;; Code:

(require 'cl-lib)

(put 'eieio--defalias 'byte-hunk-handler
     #'byte-compile-file-form-defalias) ;;(get 'defalias 'byte-hunk-handler)
(defun eieio--defalias (name body)
  "Like `defalias', but with less side-effects.
More specifically, it has no side-effects at all when the new function
definition is the same (`eq') as the old one."
  (while (and (fboundp name) (symbolp (symbol-function name)))
    ;; Follow aliases, so methods applied to obsolete aliases still work.
    (setq name (symbol-function name)))
  (unless (and (fboundp name)
               (eq (symbol-function name) body))
    (defalias name body)))

;;;
;; A few functions that are better in the official EIEIO src, but
;; used from the core.
(declare-function slot-unbound "eieio")
(declare-function slot-missing "eieio")
(declare-function child-of-class-p "eieio")


;;;
;; Variable declarations.
;;
(defvar eieio-hook nil
  "This hook is executed, then cleared each time `defclass' is called.")

(defvar eieio-error-unsupported-class-tags nil
  "Non-nil to throw an error if an encountered tag is unsupported.
This may prevent classes from CLOS applications from being used with EIEIO
since EIEIO does not support all CLOS tags.")

(defvar eieio-skip-typecheck nil
  "If non-nil, skip all slot typechecking.
Set this to t permanently if a program is functioning well to get a
small speed increase.  This variable is also used internally to handle
default setting for optimization purposes.")

(defvar eieio-optimize-primary-methods-flag t
  "Non-nil means to optimize the method dispatch on primary methods.")

(defvar eieio-initializing-object  nil
  "Set to non-nil while initializing an object.")

(defvar eieio-backward-compatibility t
  "If nil, drop support for some behaviors of older versions of EIEIO.
Currently under control of this var:
- Define every class as a var whose value is the class symbol.
- Define <class>-child-p and <class>-list-p predicates.
- Allow object names in constructors.")

(defconst eieio-unbound
  (if (and (boundp 'eieio-unbound) (symbolp eieio-unbound))
      eieio-unbound
    (make-symbol "unbound"))
  "Uninterned symbol representing an unbound slot in an object.")

;; This is a bootstrap for eieio-default-superclass so it has a value
;; while it is being built itself.
(defvar eieio-default-superclass nil)

;;;
;; Class currently in scope.
;;
;; When invoking methods, the running method needs to know which class
;; is currently in scope.  Generally this is the class of the method
;; being called, but 'call-next-method' needs to query this state,
;; and change it to be then next super class up.
;;
;; Thus, the scoped class is a stack that needs to be managed.

(defvar eieio--scoped-class-stack nil
  "A stack of the classes currently in scope during method invocation.")

(defun eieio--scoped-class ()
  "Return the class object currently in scope, or nil."
  (car-safe eieio--scoped-class-stack))

(defmacro eieio--with-scoped-class (class &rest forms)
  "Set CLASS as the currently scoped class while executing FORMS."
  (declare (indent 1))
  `(let ((eieio--scoped-class-stack (cons ,class eieio--scoped-class-stack)))
     ,@forms))

;;;
;; Field Accessors
;;
(defmacro eieio--define-field-accessors (prefix fields)
  (declare (indent 1))
  (let ((index 0)
        (defs '()))
    (dolist (field fields)
      (let ((doc (if (listp field)
                     (prog1 (cadr field) (setq field (car field))))))
        (push `(defmacro ,(intern (format "eieio--%s-%s" prefix field)) (x)
                 ,@(if doc (list (format (if (string-match "\n" doc)
                                             "Return %s" "Return %s of a %s.")
                                         doc prefix)))
                 (list 'aref x ,index))
              defs)
        (setq index (1+ index))))
    `(eval-and-compile
       ,@(nreverse defs)
       (defconst ,(intern (format "eieio--%s-num-slots" prefix)) ,index))))

(eieio--define-field-accessors class
  (-unused-0 ;;Constant slot, set to `defclass'.
   (symbol "symbol (self-referencing)")
   parent children
   (symbol-hashtable "hashtable permitting fast access to variable position indexes")
   ;; @todo
   ;; the word "public" here is leftovers from the very first version.
   ;; Get rid of it!
   (public-a "class attribute index")
   (public-d "class attribute defaults index")
   (public-doc "class documentation strings for attributes")
   (public-type "class type for a slot")
   (public-custom "class custom type for a slot")
   (public-custom-label "class custom group for a slot")
   (public-custom-group "class custom group for a slot")
   (public-printer "printer for a slot")
   (protection "protection for a slot")
   (initarg-tuples "initarg tuples list")
   (class-allocation-a "class allocated attributes")
   (class-allocation-doc "class allocated documentation")
   (class-allocation-type "class allocated value type")
   (class-allocation-custom "class allocated custom descriptor")
   (class-allocation-custom-label "class allocated custom descriptor")
   (class-allocation-custom-group "class allocated custom group")
   (class-allocation-printer "class allocated printer for a slot")
   (class-allocation-protection "class allocated protection list")
   (class-allocation-values "class allocated value vector")
   (default-object-cache "what a newly created object would look like.
This will speed up instantiation time as only a `copy-sequence' will
be needed, instead of looping over all the values and setting them
from the default.")
   (options "storage location of tagged class options.
Stored outright without modifications or stripping.")))

(eieio--define-field-accessors object
  ;; `class-tag' holds a symbol, which is not the class name, but is instead
  ;; properly prefixed as an internal EIEIO thingy and which holds the class
  ;; object/struct in its `symbol-value' slot.
  ((class-tag "tag containing the class struct")))

(defsubst eieio--object-class-object (obj)
  (symbol-value (eieio--object-class-tag obj)))

(defsubst eieio--object-class-name (obj)
  ;; FIXME: Most uses of this function should be changed to use
  ;; eieio--object-class-object instead!
  (eieio--class-symbol (eieio--object-class-object obj)))

;; FIXME: The constants below should have an `eieio-' prefix added!!
(defconst eieio--method-static 0 "Index into :static tag on a method.")
(defconst eieio--method-before 1 "Index into :before tag on a method.")
(defconst eieio--method-primary 2 "Index into :primary tag on a method.")
(defconst eieio--method-after 3 "Index into :after tag on a method.")
(defconst eieio--method-num-lists 4 "Number of indexes into methods vector in which groups of functions are kept.")
(defconst eieio--method-generic-before 4 "Index into generic :before tag on a method.")
(defconst eieio--method-generic-primary 5 "Index into generic :primary tag on a method.")
(defconst eieio--method-generic-after 6 "Index into generic :after tag on a method.")
(defconst eieio--method-num-slots 7 "Number of indexes into a method's vector.")

(defsubst eieio-specialized-key-to-generic-key (key)
  "Convert a specialized KEY into a generic method key."
  (cond ((eq key eieio--method-static) 0) ;; don't convert
	((< key eieio--method-num-lists) (+ key 3)) ;; The conversion
	(t key) ;; already generic.. maybe.
	))


;;; Important macros used internally in eieio.
;;
(defmacro eieio--check-type (type obj)
  (unless (symbolp obj)
    (error "eieio--check-type wants OBJ to be a variable"))
  `(if (not ,(cond
              ((eq 'or (car-safe type))
               `(or ,@(mapcar (lambda (type) `(,type ,obj)) (cdr type))))
              (t `(,type ,obj))))
       (signal 'wrong-type-argument (list ',type ,obj))))

(defmacro eieio--class-v (class)        ;Use a macro, so it acts as a GV place.
  "Internal: Return the class vector from the CLASS symbol."
  (declare (debug t))
  ;; No check: If eieio gets this far, it has probably been checked already.
  `(get ,class 'eieio-class-definition))

(defsubst eieio--class-object (class)
  "Return the class object."
  (if (symbolp class)
      ;; Keep the symbol if class-v is nil, for better error messages.
      (or (eieio--class-v class) class)
    class))

(defsubst eieio--class-p (class)
  "Return non-nil if CLASS is a valid class object."
  (condition-case nil
      (eq (aref class 0) 'defclass)
    (error nil)))

(defsubst eieio-class-object (class)
  "Check that CLASS is a class and return the corresponding object."
  (let ((c (eieio--class-object class)))
    (eieio--check-type eieio--class-p c)
    c))

(defsubst class-p (class)
  "Return non-nil if CLASS is a valid class vector.
CLASS is a symbol."                     ;FIXME: Is it a vector or a symbol?
  ;; this new method is faster since it doesn't waste time checking lots of
  ;; things.
  (condition-case nil
      (eq (aref (eieio--class-v class) 0) 'defclass)
    (error nil)))

(defun eieio-class-name (class)
  "Return a Lisp like symbol name for CLASS."
  ;; FIXME: What's a "Lisp like symbol name"?
  ;; FIXME: CLOS returns a symbol, but the code returns a string.
  (if (eieio--class-p class) (setq class (eieio--class-symbol class)))
  (eieio--check-type class-p class)
  ;; I think this is supposed to return a symbol, but to me CLASS is a symbol,
  ;; and I wanted a string.  Arg!
  (format "#<class %s>" (symbol-name class)))
(define-obsolete-function-alias 'class-name #'eieio-class-name "24.4")

(defmacro class-constructor (class)
  "Return the symbol representing the constructor of CLASS."
  (declare (debug t))
  `(eieio--class-symbol (eieio--class-v ,class)))

(defsubst generic-p (method)
  "Return non-nil if symbol METHOD is a generic function.
Only methods have the symbol `eieio-method-hashtable' as a property
\(which contains a list of all bindings to that method type.)"
  (and (fboundp method) (get method 'eieio-method-hashtable)))

(defun generic-primary-only-p (method)
  "Return t if symbol METHOD is a generic function with only primary methods.
Only methods have the symbol `eieio-method-hashtable' as a property (which
contains a list of all bindings to that method type.)
Methods with only primary implementations are executed in an optimized way."
  (and (generic-p method)
       (let ((M (get method 'eieio-method-tree)))
	 (not (or (>= 0 (length (aref M eieio--method-primary)))
                  (aref M eieio--method-static)
                  (aref M eieio--method-before)
                  (aref M eieio--method-after)
                  (aref M eieio--method-generic-before)
                  (aref M eieio--method-generic-primary)
                  (aref M eieio--method-generic-after)))
         )))

(defun generic-primary-only-one-p (method)
  "Return t if symbol METHOD is a generic function with only primary methods.
Only methods have the symbol `eieio-method-hashtable' as a property (which
contains a list of all bindings to that method type.)
Methods with only primary implementations are executed in an optimized way."
  (and (generic-p method)
       (let ((M (get method 'eieio-method-tree)))
	 (not (or (/= 1 (length (aref M eieio--method-primary)))
                  (aref M eieio--method-static)
                  (aref M eieio--method-before)
                  (aref M eieio--method-after)
                  (aref M eieio--method-generic-before)
                  (aref M eieio--method-generic-primary)
                  (aref M eieio--method-generic-after)))
         )))

(defmacro eieio--class-option-assoc (list option)
  "Return from LIST the found OPTION, or nil if it doesn't exist."
  `(car-safe (cdr (memq ,option ,list))))

(defsubst eieio--class-option (class option)
  "Return the value stored for CLASS' OPTION.
Return nil if that option doesn't exist."
  (eieio--class-option-assoc (eieio--class-options class) option))

(defsubst eieio-object-p (obj)
  "Return non-nil if OBJ is an EIEIO object."
  (and (arrayp obj)
       (condition-case nil
           (eq (aref (eieio--object-class-object obj) 0) 'defclass)
         (error nil))))

(defalias 'object-p 'eieio-object-p)

(defsubst class-abstract-p (class)
  "Return non-nil if CLASS is abstract.
Abstract classes cannot be instantiated."
  (eieio--class-option (eieio--class-v class) :abstract))

(defsubst eieio--class-method-invocation-order (class)
  "Return the invocation order of CLASS.
Abstract classes cannot be instantiated."
  (or (eieio--class-option class :method-invocation-order)
      :breadth-first))



;;;
;; Class Creation

(defvar eieio-defclass-autoload-map (make-hash-table)
  "Symbol map of superclasses we find in autoloads.")

;; We autoload this because it's used in `make-autoload'.
;;;###autoload
(defun eieio-defclass-autoload (cname superclasses filename doc)
  "Create autoload symbols for the EIEIO class CNAME.
SUPERCLASSES are the superclasses that CNAME inherits from.
DOC is the docstring for CNAME.
This function creates a mock-class for CNAME and adds it into
SUPERCLASSES as children.
It creates an autoload function for CNAME's constructor."
  ;; Assume we've already debugged inputs.

  (let* ((oldc (when (class-p cname) (eieio--class-v cname)))
	 (newc (make-vector eieio--class-num-slots nil))
	 )
    (if oldc
	nil ;; Do nothing if we already have this class.

      ;; Create the class in NEWC, but don't fill anything else in.
      (aset newc 0 'defclass)
      (setf (eieio--class-symbol newc) cname)

      (let ((clear-parent nil))
	;; No parents?
	(when (not superclasses)
	  (setq superclasses '(eieio-default-superclass)
		clear-parent t)
	  )

	;; Hook our new class into the existing structures so we can
	;; autoload it later.
	(dolist (SC superclasses)


	  ;; TODO - If we create an autoload that is in the map, that
	  ;;        map needs to be cleared!


          ;; Save the child in the parent.
          (cl-pushnew cname (if (class-p SC)
                                (eieio--class-children (eieio--class-v SC))
                              ;; Parent doesn't exist yet.
                              (gethash SC eieio-defclass-autoload-map)))

	  ;; Save parent in child.
          (push (eieio--class-v SC) (eieio--class-parent newc)))

	;; turn this into a usable self-pointing symbol
        (when eieio-backward-compatibility
          (set cname cname))

	;; Store the new class vector definition into the symbol.  We need to
	;; do this first so that we can call defmethod for the accessor.
	;; The vector will be updated by the following while loop and will not
	;; need to be stored a second time.
	(setf (eieio--class-v cname) newc)

	;; Clear the parent
	(if clear-parent (setf (eieio--class-parent newc) nil))

	;; Create an autoload on top of our constructor function.
	(autoload cname filename doc nil nil)
	(autoload (intern (concat (symbol-name cname) "-p")) filename "" nil nil)
	(autoload (intern (concat (symbol-name cname) "-child-p")) filename "" nil nil)
	(autoload (intern (concat (symbol-name cname) "-list-p")) filename "" nil nil)

	))))

(defsubst eieio-class-un-autoload (cname)
  "If class CNAME is in an autoload state, load its file."
  (autoload-do-load (symbol-function cname))) ; cname

(cl-deftype list-of (elem-type)
  `(and list
        (satisfies (lambda (list)
                     (cl-every (lambda (elem) (cl-typep elem ',elem-type))
                               list)))))

(defun eieio-defclass (cname superclasses slots options-and-doc)
  ;; FIXME: Most of this should be moved to the `defclass' macro.
  "Define CNAME as a new subclass of SUPERCLASSES.
SLOTS are the slots residing in that class definition, and options or
documentation OPTIONS-AND-DOC is the toplevel documentation for this class.
See `defclass' for more information."
  ;; Run our eieio-hook each time, and clear it when we are done.
  ;; This way people can add hooks safely if they want to modify eieio
  ;; or add definitions when eieio is loaded or something like that.
  (run-hooks 'eieio-hook)
  (setq eieio-hook nil)

  (eieio--check-type listp superclasses)

  (let* ((pname superclasses)
	 (newc (make-vector eieio--class-num-slots nil))
	 (oldc (when (class-p cname) (eieio--class-v cname)))
	 (groups nil) ;; list of groups id'd from slots
	 (options nil)
	 (clearparent nil))

    (aset newc 0 'defclass)
    (setf (eieio--class-symbol newc) cname)

    ;; If this class already existed, and we are updating its structure,
    ;; make sure we keep the old child list.  This can cause bugs, but
    ;; if no new slots are created, it also saves time, and prevents
    ;; method table breakage, particularly when the users is only
    ;; byte compiling an EIEIO file.
    (if oldc
	(setf (eieio--class-children newc) (eieio--class-children oldc))
      ;; If the old class did not exist, but did exist in the autoload map,
      ;; then adopt those children.  This is like the above, but deals with
      ;; autoloads nicely.
      (let ((children (gethash cname eieio-defclass-autoload-map)))
	(when children
          (setf (eieio--class-children newc) children)
	  (remhash cname eieio-defclass-autoload-map))))

    (cond ((and (stringp (car options-and-doc))
		(/= 1 (% (length options-and-doc) 2)))
	   (error "Too many arguments to `defclass'"))
	  ((and (symbolp (car options-and-doc))
		(/= 0 (% (length options-and-doc) 2)))
	   (error "Too many arguments to `defclass'"))
	  )

    (setq options
	  (if (stringp (car options-and-doc))
	      (cons :documentation options-and-doc)
	    options-and-doc))

    (if pname
	(progn
	  (dolist (p pname)
	    (if (and p (symbolp p))
		(if (not (class-p p))
		    ;; bad class
		    (error "Given parent class %S is not a class" p)
		  ;; good parent class...
		  ;; save new child in parent
                  (cl-pushnew cname (eieio--class-children (eieio--class-v p)))
		  ;; Get custom groups, and store them into our local copy.
		  (mapc (lambda (g) (cl-pushnew g groups :test #'equal))
			(eieio--class-option (eieio--class-v p) :custom-groups))
		  ;; save parent in child
                  (push (eieio--class-v p) (eieio--class-parent newc)))
	      (error "Invalid parent class %S" p)))
	  ;; Reverse the list of our parents so that they are prioritized in
	  ;; the same order as specified in the code.
	  (cl-callf nreverse (eieio--class-parent newc)))
      ;; If there is nothing to loop over, then inherit from the
      ;; default superclass.
      (unless (eq cname 'eieio-default-superclass)
	;; adopt the default parent here, but clear it later...
	(setq clearparent t)
        ;; save new child in parent
        (cl-pushnew cname (eieio--class-children eieio-default-superclass))
        ;; save parent in child
        (setf (eieio--class-parent newc) (list eieio-default-superclass))))

    ;; turn this into a usable self-pointing symbol;  FIXME: Why?
    (when eieio-backward-compatibility
      (set cname cname))

    ;; These two tests must be created right away so we can have self-
    ;; referencing classes.  ei, a class whose slot can contain only
    ;; pointers to itself.

    ;; Create the test function
    (let ((csym (intern (concat (symbol-name cname) "-p"))))
      (fset csym
	    `(lambda (obj)
               ,(format "Test OBJ to see if it an object of type %s" cname)
               (and (eieio-object-p obj)
                    (same-class-p obj ',cname)))))

    ;; Make sure the method invocation order  is a valid value.
    (let ((io (eieio--class-option-assoc options :method-invocation-order)))
      (when (and io (not (member io '(:depth-first :breadth-first :c3))))
	(error "Method invocation order %s is not allowed" io)
	))

    ;; Create a handy child test too
    (let ((csym (if eieio-backward-compatibility
                    (intern (concat (symbol-name cname) "-child-p"))
                  (make-symbol (concat (symbol-name cname) "-child-p")))))
      (fset csym
	    `(lambda (obj)
	       ,(format
                 "Test OBJ to see if it an object is a child of type %s"
                 cname)
	       (and (eieio-object-p obj)
		    (object-of-class-p obj ',cname))))

      ;; When using typep, (typep OBJ 'myclass) returns t for objects which
      ;; are subclasses of myclass.  For our predicates, however, it is
      ;; important for EIEIO to be backwards compatible, where
      ;; myobject-p, and myobject-child-p are different.
      ;; "cl" uses this technique to specify symbols with specific typep
      ;; test, so we can let typep have the CLOS documented behavior
      ;; while keeping our above predicate clean.

      (put cname 'cl-deftype-satisfies csym))

    ;; Create a handy list of the class test too
    (when eieio-backward-compatibility
      (let ((csym (intern (concat (symbol-name cname) "-list-p"))))
        (fset csym
              `(lambda (obj)
                 ,(format
                   "Test OBJ to see if it a list of objects which are a child of type %s"
                   cname)
                 (when (listp obj)
                   (let ((ans t)) ;; nil is valid
                     ;; Loop over all the elements of the input list, test
                     ;; each to make sure it is a child of the desired object class.
                     (while (and obj ans)
                       (setq ans (and (eieio-object-p (car obj))
                                      (object-of-class-p (car obj) ,cname)))
                       (setq obj (cdr obj)))
                     ans))))))

    ;; Before adding new slots, let's add all the methods and classes
    ;; in from the parent class.
    (eieio-copy-parents-into-subclass newc superclasses)

    ;; Store the new class vector definition into the symbol.  We need to
    ;; do this first so that we can call defmethod for the accessor.
    ;; The vector will be updated by the following while loop and will not
    ;; need to be stored a second time.
    (setf (eieio--class-v cname) newc)

    ;; Query each slot in the declaration list and mangle into the
    ;; class structure I have defined.
    (while slots
      (let* ((slot1  (car slots))
	     (name    (car slot1))
	     (slot   (cdr slot1))
	     (acces   (plist-get slot :accessor))
	     (init    (or (plist-get slot :initform)
			  (if (member :initform slot) nil
			    eieio-unbound)))
	     (initarg (plist-get slot :initarg))
	     (docstr  (plist-get slot :documentation))
	     (prot    (plist-get slot :protection))
	     (reader  (plist-get slot :reader))
	     (writer  (plist-get slot :writer))
	     (alloc   (plist-get slot :allocation))
	     (type    (plist-get slot :type))
	     (custom  (plist-get slot :custom))
	     (label   (plist-get slot :label))
	     (customg (plist-get slot :group))
	     (printer (plist-get slot :printer))

	     (skip-nil (eieio--class-option-assoc options :allow-nil-initform))
	     )

	(if eieio-error-unsupported-class-tags
	    (let ((tmp slot))
	      (while tmp
		(if (not (member (car tmp) '(:accessor
					     :initform
					     :initarg
					     :documentation
					     :protection
					     :reader
					     :writer
					     :allocation
					     :type
					     :custom
					     :label
					     :group
					     :printer
					     :allow-nil-initform
					     :custom-groups)))
		    (signal 'invalid-slot-type (list (car tmp))))
		(setq tmp (cdr (cdr tmp))))))

	;; Clean up the meaning of protection.
	(cond ((or (eq prot 'public) (eq prot :public)) (setq prot nil))
	      ((or (eq prot 'protected) (eq prot :protected)) (setq prot 'protected))
	      ((or (eq prot 'private) (eq prot :private)) (setq prot 'private))
	      ((eq prot nil) nil)
	      (t (signal 'invalid-slot-type (list :protection prot))))

	;; Make sure the :allocation parameter has a valid value.
	(if (not (or (not alloc) (eq alloc :class) (eq alloc :instance)))
	    (signal 'invalid-slot-type (list :allocation alloc)))

	;; The default type specifier is supposed to be t, meaning anything.
	(if (not type) (setq type t))

	;; Label is nil, or a string
	(if (not (or (null label) (stringp label)))
	    (signal 'invalid-slot-type (list :label label)))

	;; Is there an initarg, but allocation of class?
	(if (and initarg (eq alloc :class))
	    (message "Class allocated slots do not need :initarg"))

	;; intern the symbol so we can use it blankly
	(if initarg (set initarg initarg))

	;; The customgroup should be a list of symbols
	(cond ((null customg)
	       (setq customg '(default)))
	      ((not (listp customg))
	       (setq customg (list customg))))
	;; The customgroup better be a symbol, or list of symbols.
	(mapc (lambda (cg)
		(if (not (symbolp cg))
		    (signal 'invalid-slot-type (list :group cg))))
		customg)

	;; First up, add this slot into our new class.
	(eieio--add-new-slot newc name init docstr type custom label customg printer
			     prot initarg alloc 'defaultoverride skip-nil)

	;; We need to id the group, and store them in a group list attribute.
	(mapc (lambda (cg) (cl-pushnew cg groups :test 'equal)) customg)

	;; Anyone can have an accessor function.  This creates a function
	;; of the specified name, and also performs a `defsetf' if applicable
	;; so that users can `setf' the space returned by this function.
	(if acces
	    (progn
	      (eieio--defmethod
               acces (if (eq alloc :class) :static :primary) cname
               `(lambda (this)
                  ,(format
		       "Retrieves the slot `%s' from an object of class `%s'"
		       name cname)
                  (if (slot-boundp this ',name)
                      ;; Use oref-default for :class allocated slots, since
                      ;; these also accept the use of a class argument instead
                      ;; of an object argument.
                      (,(if (eq alloc :class) 'eieio-oref-default 'eieio-oref)
                       this ',name)
                    ;; Else - Some error?  nil?
                    nil)))

              ;; FIXME: We should move more of eieio-defclass into the
              ;; defclass macro so we don't have to use `eval' and require
              ;; `gv' at run-time.
              ;; FIXME: The defmethod above only defines a part of the generic
              ;; function, but the define-setter below affects the whole
              ;; generic function!
              (eval `(gv-define-setter ,acces (eieio--store eieio--object)
                       ;; Apparently, eieio-oset-default doesn't work like
                       ;;  oref-default and only accept class arguments!
                       (list ',(if nil ;; (eq alloc :class)
                                   'eieio-oset-default
                                 'eieio-oset)
                             eieio--object '',name
                             eieio--store)))))

	;; If a writer is defined, then create a generic method of that
	;; name whose purpose is to set the value of the slot.
	(if writer
            (eieio--defmethod
             writer nil cname
             `(lambda (this value)
                ,(format "Set the slot `%s' of an object of class `%s'"
			      name cname)
                (setf (slot-value this ',name) value))))
	;; If a reader is defined, then create a generic method
	;; of that name whose purpose is to access this slot value.
	(if reader
            (eieio--defmethod
             reader nil cname
             `(lambda (this)
                ,(format "Access the slot `%s' from object of class `%s'"
			      name cname)
                (slot-value this ',name))))
	)
      (setq slots (cdr slots)))

    ;; Now that everything has been loaded up, all our lists are backwards!
    ;; Fix that up now.
    (cl-callf nreverse (eieio--class-public-a newc))
    (cl-callf nreverse (eieio--class-public-d newc))
    (cl-callf nreverse (eieio--class-public-doc newc))
    (cl-callf (lambda (types) (apply #'vector (nreverse types)))
        (eieio--class-public-type newc))
    (cl-callf nreverse (eieio--class-public-custom newc))
    (cl-callf nreverse (eieio--class-public-custom-label newc))
    (cl-callf nreverse (eieio--class-public-custom-group newc))
    (cl-callf nreverse (eieio--class-public-printer newc))
    (cl-callf nreverse (eieio--class-protection newc))
    (cl-callf nreverse (eieio--class-initarg-tuples newc))

    ;; The storage for class-class-allocation-type needs to be turned into
    ;; a vector now.
    (cl-callf (lambda (cat) (apply #'vector cat))
        (eieio--class-class-allocation-type newc))

    ;; Also, take class allocated values, and vectorize them for speed.
    (cl-callf (lambda (cavs) (apply #'vector cavs))
        (eieio--class-class-allocation-values newc))

    ;; Attach slot symbols into a hashtable, and store the index of
    ;; this slot as the value this table.
    (let* ((cnt 0)
	   (pubsyms (eieio--class-public-a newc))
	   (prots (eieio--class-protection newc))
	   (oa (make-hash-table :test #'eq)))
      (while pubsyms
	(let ((newsym (list cnt)))
          (setf (gethash (car pubsyms) oa) newsym)
          (setq cnt (1+ cnt))
          (if (car prots) (setcdr newsym (car prots))))
	(setq pubsyms (cdr pubsyms)
	      prots (cdr prots)))
      (setf (eieio--class-symbol-hashtable newc) oa))

    ;; Create the constructor function
    (if (eieio--class-option-assoc options :abstract)
	;; Abstract classes cannot be instantiated.  Say so.
	(let ((abs (eieio--class-option-assoc options :abstract)))
	  (if (not (stringp abs))
	      (setq abs (format "Class %s is abstract" cname)))
	  (fset cname
		`(lambda (&rest stuff)
		   ,(format "You cannot create a new object of type %s" cname)
		   (error ,abs))))

      ;; Non-abstract classes need a constructor.
      (fset cname
	    `(lambda (&rest slots)
	       ,(format "Create a new object with name NAME of class type %s" cname)
               (if (and slots
                        (let ((x (car slots)))
                          (or (stringp x) (null x))))
                   (funcall (if eieio-backward-compatibility #'ignore #'message)
                            "Obsolete name %S passed to %S constructor"
                            (pop slots) ',cname))
	       (apply #'eieio-constructor ',cname slots)))
      )

    ;; Set up a specialized doc string.
    ;; Use stored value since it is calculated in a non-trivial way
    (put cname 'variable-documentation
	 (eieio--class-option-assoc options :documentation))

    ;; Save the file location where this class is defined.
    (let ((fname (if load-in-progress
		     load-file-name
		   buffer-file-name)))
      (when fname
	(when (string-match "\\.elc\\'" fname)
	  (setq fname (substring fname 0 (1- (length fname)))))
	(put cname 'class-location fname)))

    ;; We have a list of custom groups.  Store them into the options.
    (let ((g (eieio--class-option-assoc options :custom-groups)))
      (mapc (lambda (cg) (cl-pushnew cg g :test 'equal)) groups)
      (if (memq :custom-groups options)
	  (setcar (cdr (memq :custom-groups options)) g)
	(setq options (cons :custom-groups (cons g options)))))

    ;; Set up the options we have collected.
    (setf (eieio--class-options newc) options)

    ;; if this is a superclass, clear out parent (which was set to the
    ;; default superclass eieio-default-superclass)
    (if clearparent (setf (eieio--class-parent newc) nil))

    ;; Create the cached default object.
    (let ((cache (make-vector (+ (length (eieio--class-public-a newc))
                                 (eval-when-compile eieio--object-num-slots))
                              nil))
          ;; We don't strictly speaking need to use a symbol, but the old
          ;; code used the class's name rather than the class's object, so
          ;; we follow this preference for using a symbol, which is probably
          ;; convenient to keep the printed representation of such Elisp
          ;; objects readable.
          (tag (intern (format "eieio-class-tag--%s" cname))))
      (set tag newc)
      (setf (eieio--object-class-tag cache) tag)
      (let ((eieio-skip-typecheck t))
	;; All type-checking has been done to our satisfaction
	;; before this call.  Don't waste our time in this call..
	(eieio-set-defaults cache t))
      (setf (eieio--class-default-object-cache newc) cache))

    ;; Return our new class object
    ;; newc
    cname
    ))

(defsubst eieio-eval-default-p (val)
  "Whether the default value VAL should be evaluated for use."
  (and (consp val) (symbolp (car val)) (fboundp (car val))))

(defun eieio--perform-slot-validation-for-default (slot spec value skipnil)
  "For SLOT, signal if SPEC does not match VALUE.
If SKIPNIL is non-nil, then if VALUE is nil return t instead."
  (if (not (or (eieio-eval-default-p value) ;FIXME: Why?
               eieio-skip-typecheck
               (and skipnil (null value))
               (eieio--perform-slot-validation spec value)))
      (signal 'invalid-slot-type (list slot spec value))))

(defun eieio--add-new-slot (newc a d doc type cust label custg print prot init alloc
				 &optional defaultoverride skipnil)
  "Add into NEWC attribute A.
If A already exists in NEWC, then do nothing.  If it doesn't exist,
then also add in D (default), DOC, TYPE, CUST, LABEL, CUSTG, PRINT, PROT, and INIT arg.
Argument ALLOC specifies if the slot is allocated per instance, or per class.
If optional DEFAULTOVERRIDE is non-nil, then if A exists in NEWC,
we must override its value for a default.
Optional argument SKIPNIL indicates if type checking should be skipped
if default value is nil."
  ;; Make sure we duplicate those items that are sequences.
  (condition-case nil
      (if (sequencep d) (setq d (copy-sequence d)))
    ;; This copy can fail on a cons cell with a non-cons in the cdr.  Let's skip it if it doesn't work.
    (error nil))
  (if (sequencep type) (setq type (copy-sequence type)))
  (if (sequencep cust) (setq cust (copy-sequence cust)))
  (if (sequencep custg) (setq custg (copy-sequence custg)))

  ;; To prevent override information w/out specification of storage,
  ;; we need to do this little hack.
  (if (member a (eieio--class-class-allocation-a newc)) (setq alloc :class))

  (if (or (not alloc) (and (symbolp alloc) (eq alloc :instance)))
      ;; In this case, we modify the INSTANCE version of a given slot.

      (progn

	;; Only add this element if it is so-far unique
	(if (not (member a (eieio--class-public-a newc)))
	    (progn
	      (eieio--perform-slot-validation-for-default a type d skipnil)
	      (push a (eieio--class-public-a newc))
	      (push d (eieio--class-public-d newc))
	      (push doc (eieio--class-public-doc newc))
	      (push type (eieio--class-public-type newc))
	      (push cust (eieio--class-public-custom newc))
	      (push label (eieio--class-public-custom-label newc))
	      (push custg (eieio--class-public-custom-group newc))
	      (push print (eieio--class-public-printer newc))
	      (push prot (eieio--class-protection newc))
	      (setf (eieio--class-initarg-tuples newc) (cons (cons init a) (eieio--class-initarg-tuples newc)))
	      )
	  ;; When defaultoverride is true, we are usually adding new local
	  ;; attributes which must override the default value of any slot
	  ;; passed in by one of the parent classes.
	  (when defaultoverride
	    ;; There is a match, and we must override the old value.
	    (let* ((ca (eieio--class-public-a newc))
		   (np (member a ca))
		   (num (- (length ca) (length np)))
		   (dp (if np (nthcdr num (eieio--class-public-d newc))
			 nil))
		   (tp (if np (nth num (eieio--class-public-type newc))))
		   )
	      (if (not np)
		  (error "EIEIO internal error overriding default value for %s"
			 a)
		;; If type is passed in, is it the same?
		(if (not (eq type t))
		    (if (not (equal type tp))
			(error
			 "Child slot type `%s' does not match inherited type `%s' for `%s'"
			 type tp a)))
		;; If we have a repeat, only update the initarg...
		(unless (eq d eieio-unbound)
		  (eieio--perform-slot-validation-for-default a tp d skipnil)
		  (setcar dp d))
		;; If we have a new initarg, check for it.
		(when init
		  (let* ((inits (eieio--class-initarg-tuples newc))
			 (inita (rassq a inits)))
		    ;; Replace the CAR of the associate INITA.
		    ;;(message "Initarg: %S replace %s" inita init)
		    (setcar inita init)
		    ))

		;; PLN Tue Jun 26 11:57:06 2007 : The protection is
		;; checked and SHOULD match the superclass
		;; protection. Otherwise an error is thrown. However
		;; I wonder if a more flexible schedule might be
		;; implemented.
		;;
		;; EML - We used to have (if prot... here,
		;;       but a prot of 'nil means public.
		;;
		(let ((super-prot (nth num (eieio--class-protection newc)))
		      )
		  (if (not (eq prot super-prot))
		      (error "Child slot protection `%s' does not match inherited protection `%s' for `%s'"
			     prot super-prot a)))
		;; End original PLN

		;; PLN Tue Jun 26 11:57:06 2007 :
		;; Do a non redundant combination of ancient custom
		;; groups and new ones.
		(when custg
		  (let* ((groups
			  (nthcdr num (eieio--class-public-custom-group newc)))
			 (list1 (car groups))
			 (list2 (if (listp custg) custg (list custg))))
		    (if (< (length list1) (length list2))
			(setq list1 (prog1 list2 (setq list2 list1))))
		    (dolist (elt list2)
		      (unless (memq elt list1)
			(push elt list1)))
		    (setcar groups list1)))
		;;  End PLN

		;;  PLN Mon Jun 25 22:44:34 2007 : If a new cust is
		;;  set, simply replaces the old one.
		(when cust
		  ;; (message "Custom type redefined to %s" cust)
		  (setcar (nthcdr num (eieio--class-public-custom newc)) cust))

		;; If a new label is specified, it simply replaces
		;; the old one.
		(when label
		  ;; (message "Custom label redefined to %s" label)
		  (setcar (nthcdr num (eieio--class-public-custom-label newc)) label))
		;;  End PLN

		;; PLN Sat Jun 30 17:24:42 2007 : when a new
		;; doc is specified, simply replaces the old one.
		(when doc
		  ;;(message "Documentation redefined to %s" doc)
		  (setcar (nthcdr num (eieio--class-public-doc newc))
			  doc))
		;; End PLN

		;; If a new printer is specified, it simply replaces
		;; the old one.
		(when print
		  ;; (message "printer redefined to %s" print)
		  (setcar (nthcdr num (eieio--class-public-printer newc)) print))

		)))
	  ))

    ;; CLASS ALLOCATED SLOTS
    (let ((value (eieio-default-eval-maybe d)))
      (if (not (member a (eieio--class-class-allocation-a newc)))
	  (progn
	    (eieio--perform-slot-validation-for-default a type value skipnil)
	    ;; Here we have found a :class version of a slot.  This
	    ;; requires a very different approach.
	    (push a (eieio--class-class-allocation-a newc))
	    (push doc (eieio--class-class-allocation-doc newc))
	    (push type (eieio--class-class-allocation-type newc))
	    (push cust (eieio--class-class-allocation-custom newc))
	    (push label (eieio--class-class-allocation-custom-label newc))
	    (push custg (eieio--class-class-allocation-custom-group newc))
	    (push prot (eieio--class-class-allocation-protection newc))
	    ;; Default value is stored in the 'values section, since new objects
	    ;; can't initialize from this element.
	    (push value (eieio--class-class-allocation-values newc)))
	(when defaultoverride
	  ;; There is a match, and we must override the old value.
	  (let* ((ca (eieio--class-class-allocation-a newc))
		 (np (member a ca))
		 (num (- (length ca) (length np)))
		 (dp (if np
			 (nthcdr num
				 (eieio--class-class-allocation-values newc))
		       nil))
		 (tp (if np (nth num (eieio--class-class-allocation-type newc))
		       nil)))
	    (if (not np)
		(error "EIEIO internal error overriding default value for %s"
		       a)
	      ;; If type is passed in, is it the same?
	      (if (not (eq type t))
		  (if (not (equal type tp))
		      (error
		       "Child slot type `%s' does not match inherited type `%s' for `%s'"
		       type tp a)))
	      ;; EML - Note: the only reason to override a class bound slot
	      ;;       is to change the default, so allow unbound in.

	      ;; If we have a repeat, only update the value...
	      (eieio--perform-slot-validation-for-default a tp value skipnil)
	      (setcar dp value))

	    ;; PLN Tue Jun 26 11:57:06 2007 : The protection is
	    ;; checked and SHOULD match the superclass
	    ;; protection. Otherwise an error is thrown. However
	    ;; I wonder if a more flexible schedule might be
	    ;; implemented.
	    (let ((super-prot
		   (car (nthcdr num (eieio--class-class-allocation-protection newc)))))
	      (if (not (eq prot super-prot))
		  (error "Child slot protection `%s' does not match inherited protection `%s' for `%s'"
			 prot super-prot a)))
	    ;; Do a non redundant combination of ancient custom groups
	    ;; and new ones.
	    (when custg
	      (let* ((groups
		      (nthcdr num (eieio--class-class-allocation-custom-group newc)))
		     (list1 (car groups))
		     (list2 (if (listp custg) custg (list custg))))
		(if (< (length list1) (length list2))
		    (setq list1 (prog1 list2 (setq list2 list1))))
		(dolist (elt list2)
		  (unless (memq elt list1)
		    (push elt list1)))
		(setcar groups list1)))

	    ;; PLN Sat Jun 30 17:24:42 2007 : when a new
	    ;; doc is specified, simply replaces the old one.
	    (when doc
	      ;;(message "Documentation redefined to %s" doc)
	      (setcar (nthcdr num (eieio--class-class-allocation-doc newc))
		      doc))
	    ;; End PLN

	    ;; If a new printer is specified, it simply replaces
	    ;; the old one.
	    (when print
	      ;; (message "printer redefined to %s" print)
	      (setcar (nthcdr num (eieio--class-class-allocation-printer newc)) print))

	    ))
	))
    ))

(defun eieio-copy-parents-into-subclass (newc _parents)
  "Copy into NEWC the slots of PARENTS.
Follow the rules of not overwriting early parents when applying to
the new child class."
  (let ((sn (eieio--class-option-assoc (eieio--class-options newc)
                                       :allow-nil-initform)))
    (dolist (pcv (eieio--class-parent newc))
      ;; First, duplicate all the slots of the parent.
      (let ((pa (eieio--class-public-a pcv))
            (pd (eieio--class-public-d pcv))
            (pdoc (eieio--class-public-doc pcv))
            (ptype (eieio--class-public-type pcv))
            (pcust (eieio--class-public-custom pcv))
            (plabel (eieio--class-public-custom-label pcv))
            (pcustg (eieio--class-public-custom-group pcv))
            (printer (eieio--class-public-printer pcv))
            (pprot (eieio--class-protection pcv))
            (pinit (eieio--class-initarg-tuples pcv))
            (i 0))
        (while pa
          (eieio--add-new-slot newc
                               (car pa) (car pd) (car pdoc) (aref ptype i)
                               (car pcust) (car plabel) (car pcustg)
                               (car printer)
                               (car pprot) (car-safe (car pinit)) nil nil sn)
          ;; Increment each value.
          (setq pa (cdr pa)
                pd (cdr pd)
                pdoc (cdr pdoc)
                i (1+ i)
                pcust (cdr pcust)
                plabel (cdr plabel)
                pcustg (cdr pcustg)
                printer (cdr printer)
                pprot (cdr pprot)
                pinit (cdr pinit))
          )) ;; while/let
      ;; Now duplicate all the class alloc slots.
      (let ((pa (eieio--class-class-allocation-a pcv))
            (pdoc (eieio--class-class-allocation-doc pcv))
            (ptype (eieio--class-class-allocation-type pcv))
            (pcust (eieio--class-class-allocation-custom pcv))
            (plabel (eieio--class-class-allocation-custom-label pcv))
            (pcustg (eieio--class-class-allocation-custom-group pcv))
            (printer (eieio--class-class-allocation-printer pcv))
            (pprot (eieio--class-class-allocation-protection pcv))
            (pval (eieio--class-class-allocation-values pcv))
            (i 0))
        (while pa
          (eieio--add-new-slot newc
                               (car pa) (aref pval i) (car pdoc) (aref ptype i)
                               (car pcust) (car plabel) (car pcustg)
                               (car printer)
                               (car pprot) nil :class sn)
          ;; Increment each value.
          (setq pa (cdr pa)
                pdoc (cdr pdoc)
                pcust (cdr pcust)
                plabel (cdr plabel)
                pcustg (cdr pcustg)
                printer (cdr printer)
                pprot (cdr pprot)
                i (1+ i))
          )))))


;;; CLOS methods and generics
;;

(defun eieio--defgeneric-init-form (method doc-string)
  "Form to use for the initial definition of a generic."
  (while (and (fboundp method) (symbolp (symbol-function method)))
    ;; Follow aliases, so methods applied to obsolete aliases still work.
    (setq method (symbol-function method)))

  (cond
   ((or (not (fboundp method))
        (eq 'autoload (car-safe (symbol-function method))))
    ;; Make sure the method tables are installed.
    (eieiomt-install method)
    ;; Construct the actual body of this function.
    (put method 'function-documentation doc-string)
    (eieio-defgeneric-form method))
   ((generic-p method) (symbol-function method))           ;Leave it as-is.
   (t (error "You cannot create a generic/method over an existing symbol: %s"
             method))))

(defun eieio-defgeneric-form (method)
  "The lambda form that would be used as the function defined on METHOD.
All methods should call the same EIEIO function for dispatch.
DOC-STRING is the documentation attached to METHOD."
  (lambda (&rest local-args)
    (eieio-generic-call method local-args)))

(defun eieio--defgeneric-form-primary-only (method)
  "The lambda form that would be used as the function defined on METHOD.
All methods should call the same EIEIO function for dispatch.
DOC-STRING is the documentation attached to METHOD."
  (lambda (&rest local-args)
    (eieio--generic-call-primary-only method local-args)))

(declare-function no-applicable-method "eieio" (object method &rest args))

(defvar eieio-generic-call-arglst nil
  "When using `call-next-method', provides a context for parameters.")
(defvar eieio-generic-call-key nil
  "When using `call-next-method', provides a context for the current key.
Keys are a number representing :before, :primary, and :after methods.")
(defvar eieio-generic-call-next-method-list nil
  "When executing a PRIMARY or STATIC method, track the 'next-method'.
During executions, the list is first generated, then as each next method
is called, the next method is popped off the stack.")

(defun eieio--defgeneric-form-primary-only-one (method class impl)
  "The lambda form that would be used as the function defined on METHOD.
All methods should call the same EIEIO function for dispatch.
CLASS is the class symbol needed for private method access.
IMPL is the symbol holding the method implementation."
  (lambda (&rest local-args)
    ;; This is a cool cheat.  Usually we need to look up in the
    ;; method table to find out if there is a method or not.  We can
    ;; instead make that determination at load time when there is
    ;; only one method.  If the first arg is not a child of the class
    ;; of that one implementation, then clearly, there is no method def.
    (if (not (eieio-object-p (car local-args)))
        ;; Not an object.  Just signal.
        (signal 'no-method-definition
                (list method local-args))

      ;; We do have an object.  Make sure it is the right type.
      (if (not (child-of-class-p (eieio--object-class-object (car local-args))
                                 class))

          ;; If not the right kind of object, call no applicable
          (apply #'no-applicable-method (car local-args)
                 method local-args)

        ;; It is ok, do the call.
        ;; Fill in inter-call variables then evaluate the method.
        (let ((eieio-generic-call-next-method-list nil)
              (eieio-generic-call-key eieio--method-primary)
              (eieio-generic-call-arglst local-args)
              )
          (eieio--with-scoped-class (eieio--class-v class)
            (apply impl local-args)))))))

(defun eieio-unbind-method-implementations (method)
  "Make the generic method METHOD have no implementations.
It will leave the original generic function in place,
but remove reference to all implementations of METHOD."
  (put method 'eieio-method-tree nil)
  (put method 'eieio-method-hashtable nil))

(defun eieio--method-optimize-primary (method)
  (when eieio-optimize-primary-methods-flag
    ;; Optimizing step:
    ;;
    ;; If this method, after this setup, only has primary methods, then
    ;; we can setup the generic that way.
    (let ((doc-string (documentation method 'raw)))
      (put method 'function-documentation doc-string)
      ;; Use `defalias' so as to interact properly with nadvice.el.
      (defalias method
        (if (generic-primary-only-p method)
            ;; If there is only one primary method, then we can go one more
            ;; optimization step.
            (if (generic-primary-only-one-p method)
                (let* ((M (get method 'eieio-method-tree))
                       (entry (car (aref M eieio--method-primary))))
                  (eieio--defgeneric-form-primary-only-one
                   method (car entry) (cdr entry)))
              (eieio--defgeneric-form-primary-only method))
          (eieio-defgeneric-form method))))))

(defun eieio--defmethod (method kind argclass code)
  "Work part of the `defmethod' macro defining METHOD with ARGS."
  (let ((key
         ;; Find optional keys.
         (cond ((memq kind '(:BEFORE :before)) eieio--method-before)
               ((memq kind '(:AFTER :after)) eieio--method-after)
               ((memq kind '(:STATIC :static)) eieio--method-static)
               ((memq kind '(:PRIMARY :primary nil)) eieio--method-primary)
               ;; Primary key.
               ;; (t eieio--method-primary)
               (t (error "Unknown method kind %S" kind)))))

    (while (and (fboundp method) (symbolp (symbol-function method)))
      ;; Follow aliases, so methods applied to obsolete aliases still work.
      (setq method (symbol-function method)))

    ;; Make sure there is a generic (when called from defclass).
    (eieio--defalias
     method (eieio--defgeneric-init-form
             method (or (documentation code)
                        (format "Generically created method `%s'." method))))
    ;; Create symbol for property to bind to.  If the first arg is of
    ;; the form (varname vartype) and `vartype' is a class, then
    ;; that class will be the type symbol.  If not, then it will fall
    ;; under the type `primary' which is a non-specific calling of the
    ;; function.
    (if argclass
        (if (not (class-p argclass))    ;FIXME: Accept cl-defstructs!
            (error "Unknown class type %s in method parameters"
                   argclass))
      ;; Generics are higher.
      (setq key (eieio-specialized-key-to-generic-key key)))
    ;; Put this lambda into the symbol so we can find it.
    (eieiomt-add method code key argclass)
    )

  (eieio--method-optimize-primary method)

  method)

;;; Slot type validation

;; This is a hideous hack for replacing `typep' from cl-macs, to avoid
;; requiring the CL library at run-time.  It can be eliminated if/when
;; `typep' is merged into Emacs core.

(defun eieio--perform-slot-validation (spec value)
  "Return non-nil if SPEC does not match VALUE."
  (or (eq spec t)			; t always passes
      (eq value eieio-unbound)		; unbound always passes
      (cl-typep value spec)))

(defun eieio--validate-slot-value (class slot-idx value slot)
  "Make sure that for CLASS referencing SLOT-IDX, VALUE is valid.
Checks the :type specifier.
SLOT is the slot that is being checked, and is only used when throwing
an error."
  (if eieio-skip-typecheck
      nil
    ;; Trim off object IDX junk added in for the object index.
    (setq slot-idx (- slot-idx (eval-when-compile eieio--object-num-slots)))
    (let ((st (aref (eieio--class-public-type class) slot-idx)))
      (if (not (eieio--perform-slot-validation st value))
	  (signal 'invalid-slot-type
                  (list (eieio--class-symbol class) slot st value))))))

(defun eieio--validate-class-slot-value (class slot-idx value slot)
  "Make sure that for CLASS referencing SLOT-IDX, VALUE is valid.
Checks the :type specifier.
SLOT is the slot that is being checked, and is only used when throwing
an error."
  (if eieio-skip-typecheck
      nil
    (let ((st (aref (eieio--class-class-allocation-type class)
		    slot-idx)))
      (if (not (eieio--perform-slot-validation st value))
	  (signal 'invalid-slot-type
                  (list (eieio--class-symbol class) slot st value))))))

(defun eieio-barf-if-slot-unbound (value instance slotname fn)
  "Throw a signal if VALUE is a representation of an UNBOUND slot.
INSTANCE is the object being referenced.  SLOTNAME is the offending
slot.  If the slot is ok, return VALUE.
Argument FN is the function calling this verifier."
  (if (and (eq value eieio-unbound) (not eieio-skip-typecheck))
      (slot-unbound instance (eieio--object-class-name instance) slotname fn)
    value))


;;; Get/Set slots in an object.
;;
(defun eieio-oref (obj slot)
  "Return the value in OBJ at SLOT in the object vector."
  (eieio--check-type (or eieio-object-p class-p) obj)
  (eieio--check-type symbolp slot)
  (if (class-p obj) (eieio-class-un-autoload obj))
  (let* ((class (cond ((symbolp obj)
                       (error "eieio-oref called on a class!")
                       (eieio--class-v obj))
                      (t (eieio--object-class-object obj))))
	 (c (eieio--slot-name-index class obj slot)))
    (if (not c)
	;; It might be missing because it is a :class allocated slot.
	;; Let's check that info out.
	(if (setq c (eieio--class-slot-name-index class slot))
	    ;; Oref that slot.
	    (aref (eieio--class-class-allocation-values class) c)
	  ;; The slot-missing method is a cool way of allowing an object author
	  ;; to intercept missing slot definitions.  Since it is also the LAST
	  ;; thing called in this fn, its return value would be retrieved.
	  (slot-missing obj slot 'oref)
	  ;;(signal 'invalid-slot-name (list (eieio-object-name obj) slot))
	  )
      (eieio--check-type eieio-object-p obj)
      (eieio-barf-if-slot-unbound (aref obj c) obj slot 'oref))))


(defun eieio-oref-default (obj slot)
  "Do the work for the macro `oref-default' with similar parameters.
Fills in OBJ's SLOT with its default value."
  (eieio--check-type (or eieio-object-p class-p) obj)
  (eieio--check-type symbolp slot)
  (let* ((cl (cond ((symbolp obj) (eieio--class-v obj))
                   (t (eieio--object-class-object obj))))
	 (c (eieio--slot-name-index cl obj slot)))
    (if (not c)
	;; It might be missing because it is a :class allocated slot.
	;; Let's check that info out.
	(if (setq c
		  (eieio--class-slot-name-index cl slot))
	    ;; Oref that slot.
	    (aref (eieio--class-class-allocation-values cl)
		  c)
	  (slot-missing obj slot 'oref-default)
	  ;;(signal 'invalid-slot-name (list (class-name cl) slot))
	  )
      (eieio-barf-if-slot-unbound
       (let ((val (nth (- c (eval-when-compile eieio--object-num-slots))
                       (eieio--class-public-d cl))))
	 (eieio-default-eval-maybe val))
       obj (eieio--class-symbol cl) 'oref-default))))

(defun eieio-default-eval-maybe (val)
  "Check VAL, and return what `oref-default' would provide."
  ;; FIXME: What the hell is this supposed to do?  Shouldn't it evaluate
  ;; variables as well?  Why not just always call `eval'?
  (cond
   ;; Is it a function call?  If so, evaluate it.
   ((eieio-eval-default-p val)
    (eval val))
   ;;;; check for quoted things, and unquote them
   ;;((and (consp val) (eq (car val) 'quote))
   ;; (car (cdr val)))
   ;; return it verbatim
   (t val)))

(defun eieio-oset (obj slot value)
  "Do the work for the macro `oset'.
Fills in OBJ's SLOT with VALUE."
  (eieio--check-type eieio-object-p obj)
  (eieio--check-type symbolp slot)
  (let* ((class (eieio--object-class-object obj))
         (c (eieio--slot-name-index class obj slot)))
    (if (not c)
	;; It might be missing because it is a :class allocated slot.
	;; Let's check that info out.
	(if (setq c
		  (eieio--class-slot-name-index class slot))
	    ;; Oset that slot.
	    (progn
	      (eieio--validate-class-slot-value class c value slot)
	      (aset (eieio--class-class-allocation-values class)
		    c value))
	  ;; See oref for comment on `slot-missing'
	  (slot-missing obj slot 'oset value)
	  ;;(signal 'invalid-slot-name (list (eieio-object-name obj) slot))
	  )
      (eieio--validate-slot-value class c value slot)
      (aset obj c value))))

(defun eieio-oset-default (class slot value)
  "Do the work for the macro `oset-default'.
Fills in the default value in CLASS' in SLOT with VALUE."
  (setq class (eieio--class-object class))
  (eieio--check-type eieio--class-p class)
  (eieio--check-type symbolp slot)
  (eieio--with-scoped-class class
    (let* ((c (eieio--slot-name-index class nil slot)))
      (if (not c)
	  ;; It might be missing because it is a :class allocated slot.
	  ;; Let's check that info out.
	  (if (setq c (eieio--class-slot-name-index class slot))
	      (progn
		;; Oref that slot.
		(eieio--validate-class-slot-value class c value slot)
		(aset (eieio--class-class-allocation-values class) c
		      value))
	    (signal 'invalid-slot-name (list (eieio--class-symbol class) slot)))
	(eieio--validate-slot-value class c value slot)
	;; Set this into the storage for defaults.
	(setcar (nthcdr (- c (eval-when-compile eieio--object-num-slots))
                        (eieio--class-public-d class))
		value)
	;; Take the value, and put it into our cache object.
	(eieio-oset (eieio--class-default-object-cache class)
		    slot value)
	))))


;;; EIEIO internal search functions
;;
(defun eieio--slot-originating-class-p (start-class slot)
  "Return non-nil if START-CLASS is the first class to define SLOT.
This is for testing if the class currently in scope is the class that defines SLOT
so that we can protect private slots."
  (let ((par (eieio--class-parent start-class))
	(ret t))
    (or (not par)
        (progn
          (while (and par ret)
            (if (gethash slot (eieio--class-symbol-hashtable (car par)))
                (setq ret nil))
            (setq par (cdr par)))
          ret))))

(defun eieio--slot-name-index (class obj slot)
  "In CLASS for OBJ find the index of the named SLOT.
The slot is a symbol which is installed in CLASS by the `defclass'
call.  OBJ can be nil, but if it is an object, and the slot in question
is protected, access will be allowed if OBJ is a child of the currently
scoped class.
If SLOT is the value created with :initarg instead,
reverse-lookup that name, and recurse with the associated slot value."
  ;; Removed checks to outside this call
  (let* ((fsym (gethash slot (eieio--class-symbol-hashtable class)))
	 (fsi (car fsym)))
    (if (integerp fsi)
	(cond
	 ((not (cdr fsym))
	  (+ (eval-when-compile eieio--object-num-slots) fsi))
	 ((and (eq (cdr fsym) 'protected)
	       (eieio--scoped-class)
	       (or (child-of-class-p class (eieio--scoped-class))
		   (and (eieio-object-p obj)
                        ;; AFAICT, for all callers, if `obj' is not a class,
                        ;; then its class is `class'.
			;;(child-of-class-p class (eieio--object-class-object obj))
                        (progn
                          (cl-assert (eq class (eieio--object-class-object obj)))
                          t))))
	  (+ (eval-when-compile eieio--object-num-slots) fsi))
	 ((and (eq (cdr fsym) 'private)
	       (or (and (eieio--scoped-class)
			(eieio--slot-originating-class-p
                         (eieio--scoped-class) slot))
		   eieio-initializing-object))
	  (+ (eval-when-compile eieio--object-num-slots) fsi))
	 (t nil))
      (let ((fn (eieio--initarg-to-attribute class slot)))
	(if fn (eieio--slot-name-index class obj fn) nil)))))

(defun eieio--class-slot-name-index (class slot)
  "In CLASS find the index of the named SLOT.
The slot is a symbol which is installed in CLASS by the `defclass'
call.  If SLOT is the value created with :initarg instead,
reverse-lookup that name, and recurse with the associated slot value."
  ;; This will happen less often, and with fewer slots.  Do this the
  ;; storage cheap way.
  (let* ((a (eieio--class-class-allocation-a class))
	 (l1 (length a))
	 (af (memq slot a))
	 (l2 (length af)))
    ;; Slot # is length of the total list, minus the remaining list of
    ;; the found slot.
    (if af (- l1 l2))))

;;;
;; Way to assign slots based on a list.  Used for constructors, or
;; even resetting an object at run-time
;;
(defun eieio-set-defaults (obj &optional set-all)
  "Take object OBJ, and reset all slots to their defaults.
If SET-ALL is non-nil, then when a default is nil, that value is
reset.  If SET-ALL is nil, the slots are only reset if the default is
not nil."
  (eieio--with-scoped-class (eieio--object-class-object obj)
    (let ((eieio-initializing-object t)
	  (pub (eieio--class-public-a (eieio--object-class-object obj))))
      (while pub
	(let ((df (eieio-oref-default obj (car pub))))
	  (if (or df set-all)
	      (eieio-oset obj (car pub) df)))
	(setq pub (cdr pub))))))

(defun eieio--initarg-to-attribute (class initarg)
  "For CLASS, convert INITARG to the actual attribute name.
If there is no translation, pass it in directly (so we can cheat if
need be... May remove that later...)"
  (let ((tuple (assoc initarg (eieio--class-initarg-tuples class))))
    (if tuple
	(cdr tuple)
      nil)))

;;;
;; Method Invocation order: C3
(defun eieio--c3-candidate (class remaining-inputs)
  "Return CLASS if it can go in the result now, otherwise nil."
  ;; Ensure CLASS is not in any position but the first in any of the
  ;; element lists of REMAINING-INPUTS.
  (and (not (let ((found nil))
	      (while (and remaining-inputs (not found))
		(setq found (member class (cdr (car remaining-inputs)))
		      remaining-inputs (cdr remaining-inputs)))
	      found))
       class))

(defun eieio--c3-merge-lists (reversed-partial-result remaining-inputs)
  "Merge REVERSED-PARTIAL-RESULT REMAINING-INPUTS in a consistent order, if possible.
If a consistent order does not exist, signal an error."
  (if (let ((tail remaining-inputs)
	    (found nil))
	(while (and tail (not found))
	  (setq found (car tail) tail (cdr tail)))
	(not found))
      ;; If all remaining inputs are empty lists, we are done.
      (nreverse reversed-partial-result)
    ;; Otherwise, we try to find the next element of the result. This
    ;; is achieved by considering the first element of each
    ;; (non-empty) input list and accepting a candidate if it is
    ;; consistent with the rests of the input lists.
    (let* ((found nil)
	   (tail remaining-inputs)
	   (next (progn
		   (while (and tail (not found))
		     (setq found (and (car tail)
				      (eieio--c3-candidate (caar tail)
                                                           remaining-inputs))
			   tail (cdr tail)))
		   found)))
      (if next
	  ;; The graph is consistent so far, add NEXT to result and
	  ;; merge input lists, dropping NEXT from their heads where
	  ;; applicable.
	  (eieio--c3-merge-lists
	   (cons next reversed-partial-result)
	   (mapcar (lambda (l) (if (eq (cl-first l) next) (cl-rest l) l))
		   remaining-inputs))
	;; The graph is inconsistent, give up
	(signal 'inconsistent-class-hierarchy (list remaining-inputs))))))

(defun eieio--class-precedence-c3 (class)
  "Return all parents of CLASS in c3 order."
  (let ((parents (eieio--class-parent (eieio--class-v class))))
    (eieio--c3-merge-lists
     (list class)
     (append
      (or
       (mapcar #'eieio--class-precedence-c3 parents)
       `((,eieio-default-superclass)))
      (list parents))))
  )
;;;
;; Method Invocation Order: Depth First

(defun eieio--class-precedence-dfs (class)
  "Return all parents of CLASS in depth-first order."
  (let* ((parents (eieio--class-parent class))
	 (classes (copy-sequence
		   (apply #'append
			  (list class)
			  (or
			   (mapcar
			    (lambda (parent)
			      (cons parent
				    (eieio--class-precedence-dfs parent)))
			    parents)
			   `((,eieio-default-superclass))))))
	 (tail classes))
    ;; Remove duplicates.
    (while tail
      (setcdr tail (delq (car tail) (cdr tail)))
      (setq tail (cdr tail)))
    classes))

;;;
;; Method Invocation Order: Breadth First
(defun eieio--class-precedence-bfs (class)
  "Return all parents of CLASS in breadth-first order."
  (let* ((result)
         (queue (or (eieio--class-parent class)
                    `(,eieio-default-superclass))))
    (while queue
      (let ((head (pop queue)))
	(unless (member head result)
	  (push head result)
	  (unless (eq head eieio-default-superclass)
	    (setq queue (append queue (or (eieio--class-parent head)
					  `(,eieio-default-superclass))))))))
    (cons class (nreverse result)))
  )

;;;
;; Method Invocation Order

(defun eieio--class-precedence-list (class)
  "Return (transitively closed) list of parents of CLASS.
The order, in which the parents are returned depends on the
method invocation orders of the involved classes."
  (if (or (null class) (eq class eieio-default-superclass))
      nil
    (cl-case (eieio--class-method-invocation-order class)
      (:depth-first
       (eieio--class-precedence-dfs class))
      (:breadth-first
       (eieio--class-precedence-bfs class))
      (:c3
       (eieio--class-precedence-c3 class))))
  )
(define-obsolete-function-alias
  'class-precedence-list 'eieio--class-precedence-list "24.4")


;;; CLOS generics internal function handling
;;

(define-obsolete-variable-alias 'eieio-pre-method-execution-hooks
  'eieio-pre-method-execution-functions "24.3")
(defvar eieio-pre-method-execution-functions nil
  "Abnormal hook run just before an EIEIO method is executed.
The hook function must accept one argument, the list of forms
about to be executed.")

(defun eieio-generic-call (method args)
  "Call METHOD with ARGS.
ARGS provides the context on which implementation to use.
This should only be called from a generic function."
  ;; We must expand our arguments first as they are always
  ;; passed in as quoted symbols
  (let ((newargs nil) (mclass nil)  (lambdas nil) (tlambdas nil) (keys nil)
	(eieio-generic-call-arglst args)
	(firstarg nil)
	(primarymethodlist nil))
    ;; get a copy
    (setq newargs args
	  firstarg (car newargs))
    ;; Is the class passed in autoloaded?
    ;; Since class names are also constructors, they can be autoloaded
    ;; via the autoload command.  Check for this, and load them in.
    ;; It is ok if it doesn't turn out to be a class.  Probably want that
    ;; function loaded anyway.
    (if (and (symbolp firstarg)
	     (fboundp firstarg)
	     (autoloadp (symbol-function firstarg)))
	(autoload-do-load (symbol-function firstarg)))
    ;; Determine the class to use.
    (cond ((eieio-object-p firstarg)
	   (setq mclass (eieio--object-class-name firstarg)))
	  ((class-p firstarg)
	   (setq mclass firstarg))
	  )
    ;; Make sure the class is a valid class
    ;; mclass can be nil (meaning a generic for should be used.
    ;; mclass cannot have a value that is not a class, however.
    (unless (or (null mclass) (class-p mclass))
      (error "Cannot dispatch method %S on class %S"
	     method mclass)
      )
    ;; Now create a list in reverse order of all the calls we have
    ;; make in order to successfully do this right.  Rules:
    ;; 1) Only call generics if scoped-class is not defined
    ;;    This prevents multiple calls in the case of recursion
    ;; 2) Only call static if this is a static method.
    ;; 3) Only call specifics if the definition allows for them.
    ;; 4) Call in order based on :before, :primary, and :after
    (when (eieio-object-p firstarg)
      ;; Non-static calls do all this stuff.

      ;; :after methods
      (setq tlambdas
	    (if mclass
		(eieiomt-method-list method eieio--method-after mclass)
	      (list (eieio-generic-form method eieio--method-after nil)))
	    ;;(or (and mclass (eieio-generic-form method eieio--method-after mclass))
	    ;;	(eieio-generic-form method eieio--method-after nil))
	    )
      (setq lambdas (append tlambdas lambdas)
	    keys (append (make-list (length tlambdas) eieio--method-after) keys))

      ;; :primary methods
      (setq tlambdas
	    (or (and mclass (eieio-generic-form method eieio--method-primary mclass))
		(eieio-generic-form method eieio--method-primary nil)))
      (when tlambdas
	(setq lambdas (cons tlambdas lambdas)
	      keys (cons eieio--method-primary keys)
	      primarymethodlist
	      (eieiomt-method-list method eieio--method-primary mclass)))

      ;; :before methods
      (setq tlambdas
	    (if mclass
		(eieiomt-method-list method eieio--method-before mclass)
	      (list (eieio-generic-form method eieio--method-before nil)))
	    ;;(or (and mclass (eieio-generic-form method eieio--method-before mclass))
	    ;;	(eieio-generic-form method eieio--method-before nil))
	    )
      (setq lambdas (append tlambdas lambdas)
	    keys (append (make-list (length tlambdas) eieio--method-before) keys))
      )

    (if mclass
	;; For the case of a class,
	;; if there were no methods found, then there could be :static methods.
	(when (not lambdas)
	  (setq tlambdas
		(eieio-generic-form method eieio--method-static mclass))
	  (setq lambdas (cons tlambdas lambdas)
		keys (cons eieio--method-static keys)
		primarymethodlist  ;; Re-use even with bad name here
		(eieiomt-method-list method eieio--method-static mclass)))
      ;; For the case of no class (ie - mclass == nil) then there may
      ;; be a primary method.
      (setq tlambdas
	    (eieio-generic-form method eieio--method-primary nil))
      (when tlambdas
	(setq lambdas (cons tlambdas lambdas)
	      keys (cons eieio--method-primary keys)
	      primarymethodlist
	      (eieiomt-method-list method eieio--method-primary nil)))
      )

    (run-hook-with-args 'eieio-pre-method-execution-functions
			primarymethodlist)

    ;; Now loop through all occurrences forms which we must execute
    ;; (which are happily sorted now) and execute them all!
    (let ((rval nil) (lastval nil) (found nil))
      (while lambdas
	(if (car lambdas)
	    (eieio--with-scoped-class (cdr (car lambdas))
	      (let* ((eieio-generic-call-key (car keys))
		     (has-return-val
		      (or (= eieio-generic-call-key eieio--method-primary)
			  (= eieio-generic-call-key eieio--method-static)))
		     (eieio-generic-call-next-method-list
		      ;; Use the cdr, as the first element is the fcn
		      ;; we are calling right now.
		      (when has-return-val (cdr primarymethodlist)))
		     )
		(setq found t)
		;;(setq rval (apply (car (car lambdas)) newargs))
		(setq lastval (apply (car (car lambdas)) newargs))
		(when has-return-val
		  (setq rval lastval))
		)))
	(setq lambdas (cdr lambdas)
	      keys (cdr keys)))
      (if (not found)
	  (if (eieio-object-p (car args))
	      (setq rval (apply #'no-applicable-method (car args) method args))
	    (signal
	     'no-method-definition
	     (list method args))))
      rval)))

(defun eieio--generic-call-primary-only (method args)
  "Call METHOD with ARGS for methods with only :PRIMARY implementations.
ARGS provides the context on which implementation to use.
This should only be called from a generic function.

This method is like `eieio-generic-call', but only
implementations in the :PRIMARY slot are queried.  After many
years of use, it appears that over 90% of methods in use
have :PRIMARY implementations only.  We can therefore optimize
for this common case to improve performance."
  ;; We must expand our arguments first as they are always
  ;; passed in as quoted symbols
  (let ((newargs nil) (mclass nil)  (lambdas nil)
	(eieio-generic-call-arglst args)
	(firstarg nil)
	(primarymethodlist nil)
	)
    ;; get a copy
    (setq newargs args
	  firstarg (car newargs))

    ;; Determine the class to use.
    (cond ((eieio-object-p firstarg)
	   (setq mclass (eieio--object-class-name firstarg)))
	  ((not firstarg)
	   (error "Method %s called on nil" method))
	  (t
	   (error "Primary-only method %s called on something not an object" method)))
    ;; Make sure the class is a valid class
    ;; mclass can be nil (meaning a generic for should be used.
    ;; mclass cannot have a value that is not a class, however.
    (when (null mclass)
      (error "Cannot dispatch method %S on class %S" method mclass)
      )

    ;; :primary methods
    (setq lambdas (eieio-generic-form method eieio--method-primary mclass))
    (setq primarymethodlist  ;; Re-use even with bad name here
	  (eieiomt-method-list method eieio--method-primary mclass))

    ;; Now loop through all occurrences forms which we must execute
    ;; (which are happily sorted now) and execute them all!
    (eieio--with-scoped-class (cdr lambdas)
      (let* ((rval nil) (lastval nil)
	     (eieio-generic-call-key eieio--method-primary)
	     ;; Use the cdr, as the first element is the fcn
	     ;; we are calling right now.
	     (eieio-generic-call-next-method-list (cdr primarymethodlist))
	     )

	(if (or (not lambdas) (not (car lambdas)))

	    ;; No methods found for this impl...
	    (if (eieio-object-p (car args))
		(setq rval (apply #'no-applicable-method
                                  (car args) method args))
	      (signal
	       'no-method-definition
	       (list method args)))

	  ;; Do the regular implementation here.

	  (run-hook-with-args 'eieio-pre-method-execution-functions
			      lambdas)

	  (setq lastval (apply (car lambdas) newargs))
	  (setq rval lastval))

	rval))))

(defun eieiomt-method-list (method key class)
  "Return an alist list of methods lambdas.
METHOD is the method name.
KEY represents either :before, or :after methods.
CLASS is the starting class to search from in the method tree.
If CLASS is nil, then an empty list of methods should be returned."
  ;; Note: eieiomt - the MT means MethodTree.  See more comments below
  ;; for the rest of the eieiomt methods.

  ;; Collect lambda expressions stored for the class and its parent
  ;; classes.
  (let (lambdas)
    (dolist (ancestor (eieio--class-precedence-list (eieio--class-v class)))
      ;; Lookup the form to use for the PRIMARY object for the next level
      (let ((tmpl (eieio-generic-form method key ancestor)))
	(when (and tmpl
		   (or (not lambdas)
		       ;; This prevents duplicates coming out of the
		       ;; class method optimizer.  Perhaps we should
		       ;; just not optimize before/afters?
		       (not (member tmpl lambdas))))
	  (push tmpl lambdas))))

    ;; Return collected lambda. For :after methods, return in current
    ;; order (most general class last); Otherwise, reverse order.
    (if (eq key eieio--method-after)
	lambdas
      (nreverse lambdas))))


;;;
;; eieio-method-tree : eieiomt-
;;
;; Stored as eieio-method-tree in property list of a generic method
;;
;; (eieio-method-tree . [BEFORE PRIMARY AFTER
;;                       genericBEFORE genericPRIMARY genericAFTER])
;; and
;; (eieio-method-hashtable . [BEFORE PRIMARY AFTER
;;                          genericBEFORE genericPRIMARY genericAFTER])
;;    where the association is a vector.
;;    (aref 0  -- all static methods.
;;    (aref 1  -- all methods classified as :before
;;    (aref 2  -- all methods classified as :primary
;;    (aref 3  -- all methods classified as :after
;;    (aref 4  -- a generic classified as :before
;;    (aref 5  -- a generic classified as :primary
;;    (aref 6  -- a generic classified as :after
;;
(defvar eieiomt--optimizing-hashtable nil
  "While mapping atoms, this contain the hashtable being optimized.")

(defun eieiomt-install (method-name)
  "Install the method tree, and hashtable onto METHOD-NAME.
Do not do the work if they already exist."
  (unless (and (get method-name 'eieio-method-tree)
               (get method-name 'eieio-method-hashtable))
    (put method-name 'eieio-method-tree
         (make-vector eieio--method-num-slots nil))
    (let ((emto (put method-name 'eieio-method-hashtable
                     (make-vector eieio--method-num-slots nil))))
      (aset emto 0 (make-hash-table :test 'eq))
      (aset emto 1 (make-hash-table :test 'eq))
      (aset emto 2 (make-hash-table :test 'eq))
      (aset emto 3 (make-hash-table :test 'eq)))))

(defun eieiomt-add (method-name method key class)
  "Add to METHOD-NAME the forms METHOD in a call position KEY for CLASS.
METHOD-NAME is the name created by a call to `defgeneric'.
METHOD are the forms for a given implementation.
KEY is an integer (see comment in eieio.el near this function) which
is associated with the :static :before :primary and :after tags.
It also indicates if CLASS is defined or not.
CLASS is the class this method is associated with."
  (if (or (> key eieio--method-num-slots) (< key 0))
      (error "eieiomt-add: method key error!"))
  (let ((emtv (get method-name 'eieio-method-tree))
	(emto (get method-name 'eieio-method-hashtable)))
    ;; Make sure the method tables are available.
    (unless (and emtv emto)
      (error "Programmer error: eieiomt-add"))
    ;; only add new cells on if it doesn't already exist!
    (if (assq class (aref emtv key))
	(setcdr (assq class (aref emtv key)) method)
      (aset emtv key (cons (cons class method) (aref emtv key))))
    ;; Add function definition into newly created symbol, and store
    ;; said symbol in the correct hashtable, otherwise use the
    ;; other array to keep this stuff.
    (if (< key eieio--method-num-lists)
        (puthash (eieio--class-v class) (list method) (aref emto key)))
    ;; Save the defmethod file location in a symbol property.
    (let ((fname (if load-in-progress
		     load-file-name
		   buffer-file-name)))
      (when fname
	(when (string-match "\\.elc\\'" fname)
	  (setq fname (substring fname 0 (1- (length fname)))))
	(cl-pushnew (list class fname) (get method-name 'method-locations)
                    :test 'equal)))
    ;; Now optimize the entire hashtable.
    (if (< key eieio--method-num-lists)
	(let ((eieiomt--optimizing-hashtable (aref emto key)))
	  ;; @todo - Is this overkill?  Should we just clear the symbol?
	  (maphash #'eieiomt--sym-optimize eieiomt--optimizing-hashtable)))
    ))

(defun eieiomt-next (class)
  "Return the next parent class for CLASS.
If CLASS is a superclass, return variable `eieio-default-superclass'.
If CLASS is variable `eieio-default-superclass' then return nil.
This is different from function `class-parent' as class parent returns
nil for superclasses.  This function performs no type checking!"
  ;; No type-checking because all calls are made from functions which
  ;; are safe and do checking for us.
  (or (eieio--class-parent (eieio--class-v class))
      (if (eq class 'eieio-default-superclass)
	  nil
	'(eieio-default-superclass))))

(defun eieiomt--sym-optimize (class s)
  "Find the next class above S which has a function body for the optimizer."
  ;; Set the value to nil in case there is no nearest cell.
  (setcdr s nil)
  ;; Find the nearest cell that has a function body. If we find one,
  ;; we replace the nil from above.
  (catch 'done
    (dolist (ancestor
             (cl-rest (eieio--class-precedence-list class)))
      (let ((ov (gethash ancestor eieiomt--optimizing-hashtable)))
        (when (car ov)
          (setcdr s ancestor) ;; store ov as our next symbol
          (throw 'done ancestor))))))

(defun eieio-generic-form (method key class)
 "Return the lambda form belonging to METHOD using KEY based upon CLASS.
If CLASS is not a class then use `generic' instead.  If class has
no form, but has a parent class, then trace to that parent class.
The first time a form is requested from a symbol, an optimized path
is memorized for faster future use."
 (if (symbolp class) (setq class (eieio--class-v class)))
 (let ((emto (aref (get method 'eieio-method-hashtable)
		   (if class key (eieio-specialized-key-to-generic-key key)))))
   (if (eieio--class-p class)
       ;; 1) find our symbol
       (let ((cs (gethash class emto)))
	 (unless cs
           ;; 2) If there isn't one, then make one.
           ;;    This can be slow since it only occurs once
           (puthash class (setq cs (list nil)) emto)
           ;; 2.1) Cache its nearest neighbor with a quick optimize
           ;;      which should only occur once for this call ever
           (let ((eieiomt--optimizing-hashtable emto))
             (eieiomt--sym-optimize class cs)))
	 ;; 3) If it's bound return this one.
	 (if (car cs)
	     (cons (car cs) class)
	   ;; 4) If it's not bound then this variable knows something
	   (if (cdr cs)
	       (progn
		 ;; 4.1) This symbol holds the next class in its value
		 (setq class (cdr cs)
		       cs (gethash class emto))
		 ;; 4.2) The optimizer should always have chosen a
		 ;;      function-symbol
		 ;;(if (car cs)
		 (cons (car cs) class)
                 ;;(error "EIEIO optimizer: erratic data loss!"))
		 )
             ;; There never will be a funcall...
             nil)))
     ;; for a generic call, what is a list, is the function body we want.
     (let ((emtl (aref (get method 'eieio-method-tree)
 		       (if class key (eieio-specialized-key-to-generic-key key)))))
       (if emtl
	   ;; The car of EMTL is supposed to be a class, which in this
	   ;; case is nil, so skip it.
	   (cons (cdr (car emtl)) nil)
	 nil)))))


;;; Here are some special types of errors
;;
(define-error 'no-method-definition "No method definition")
(define-error 'no-next-method "No next method")
(define-error 'invalid-slot-name "Invalid slot name")
(define-error 'invalid-slot-type "Invalid slot type")
(define-error 'unbound-slot "Unbound slot")
(define-error 'inconsistent-class-hierarchy "Inconsistent class hierarchy")

;;; Obsolete backward compatibility functions.
;; Needed to run byte-code compiled with the EIEIO of Emacs-23.

(defun eieio-defmethod (method args)
  "Obsolete work part of an old version of the `defmethod' macro."
  (let ((key nil) (body nil) (firstarg nil) (argfix nil) (argclass nil) loopa)
    ;; find optional keys
    (setq key
	  (cond ((memq (car args) '(:BEFORE :before))
		 (setq args (cdr args))
		 eieio--method-before)
		((memq (car args) '(:AFTER :after))
		 (setq args (cdr args))
		 eieio--method-after)
		((memq (car args) '(:STATIC :static))
		 (setq args (cdr args))
		 eieio--method-static)
		((memq (car args) '(:PRIMARY :primary))
		 (setq args (cdr args))
		 eieio--method-primary)
		;; Primary key.
		(t eieio--method-primary)))
    ;; Get body, and fix contents of args to be the arguments of the fn.
    (setq body (cdr args)
	  args (car args))
    (setq loopa args)
    ;; Create a fixed version of the arguments.
    (while loopa
      (setq argfix (cons (if (listp (car loopa)) (car (car loopa)) (car loopa))
			 argfix))
      (setq loopa (cdr loopa)))
    ;; Make sure there is a generic.
    (eieio-defgeneric
     method
     (if (stringp (car body))
	 (car body) (format "Generically created method `%s'." method)))
    ;; create symbol for property to bind to.  If the first arg is of
    ;; the form (varname vartype) and `vartype' is a class, then
    ;; that class will be the type symbol.  If not, then it will fall
    ;; under the type `primary' which is a non-specific calling of the
    ;; function.
    (setq firstarg (car args))
    (if (listp firstarg)
	(progn
	  (setq argclass  (nth 1 firstarg))
	  (if (not (class-p argclass))
	      (error "Unknown class type %s in method parameters"
		     (nth 1 firstarg))))
      ;; Generics are higher.
      (setq key (eieio-specialized-key-to-generic-key key)))
    ;; Put this lambda into the symbol so we can find it.
    (if (byte-code-function-p (car-safe body))
	(eieiomt-add method (car-safe body) key argclass)
      (eieiomt-add method (append (list 'lambda (reverse argfix)) body)
		   key argclass))
    )

  (eieio--method-optimize-primary method)

  method)
(make-obsolete 'eieio-defmethod 'eieio--defmethod "24.1")

(defun eieio-defgeneric (method doc-string)
  "Obsolete work part of an old version of the `defgeneric' macro."
  (if (and (fboundp method) (not (generic-p method))
	   (or (byte-code-function-p (symbol-function method))
	       (not (eq 'autoload (car (symbol-function method)))))
	   )
      (error "You cannot create a generic/method over an existing symbol: %s"
	     method))
  ;; Don't do this over and over.
  (unless (fboundp 'method)
    ;; This defun tells emacs where the first definition of this
    ;; method is defined.
    `(defun ,method nil)
    ;; Make sure the method tables are installed.
    (eieiomt-install method)
    ;; Apply the actual body of this function.
    (put method 'function-documentation doc-string)
    (fset method (eieio-defgeneric-form method))
    ;; Return the method
    'method))
(make-obsolete 'eieio-defgeneric nil "24.1")

(provide 'eieio-core)

;;; eieio-core.el ends here
