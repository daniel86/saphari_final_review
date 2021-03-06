;;; Copyright (c) 2015, Georg Bartels <georg.bartels@cs.uni-bremen.de>
;;; All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;;
;;; * Redistributions of source code must retain the above copyright
;;; notice, this list of conditions and the following disclaimer.
;;; * Redistributions in binary form must reproduce the above copyright
;;; notice, this list of conditions and the following disclaimer in the
;;; documentation and/or other materials provided with the distribution.
;;; * Neither the name of the Institute for Artificial Intelligence/
;;; Universitaet Bremen nor the names of its contributors may be used to 
;;; endorse or promote products derived from this software without specific 
;;; prior written permission.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.

(in-package :saphari-task-executive)

(defun infer-motion-goal (demo-handle desig)
  "Returns the motion goal described by 'desig'. If no matching motion
 goal exists. Throws a CRAM failure if no matching motion goal exists.
 Uses resources from 'demo-handle', e.g. tf listener."
  (or
   (infer-lookat-motion-goal desig)
   (infer-grasp-motion-goal demo-handle desig)
   (infer-put-down-motion-goal demo-handle desig)
   (cpl:fail "Could not resolve: ~a" desig)))

(defun infer-lookat-motion-goal (desig)
  "Tries to match 'desig' to its internal description of a goals
 to look at the pickup-zone, and returns the corresponding motion
 goal if the match was successful. If no match is found, it returns
 NIL."
  ;;;
  ;;; NOTE TO MYSELF: this is what I actually want to have
  ;;;
  ;;; (designator-bind ((:an action)
  ;;;                   (:to :see)
  ;;;                   (:obj ((:an :object)
  ;;;                          (:type :pickup-zone)))
  ;;;                   (:distance distance)
  ;;;                   &rest rest)) desig
  ;;;   (declare (ignore rest))
  ;;;   (lookat-pickup-config distance))
  ;;;
  ;;; Semantics:
  ;;; * only looks at descriptions, also for nested designators
  ;;; * like when-let, executes its body only when bindings were successful
  ;;; * binds non-keyword symbols as local variables in its scope
  ;;; * binds any un-matched parts of the description to local variable 'rest'
  ;;; * if &rest is not specified, it will fail in case of un-matched parts in desig
  ;;;
  (or
   (and
    (desig-descr-included
     (action-designator
      `((:an :action)
        (:to :move)
        (:at ,(location-designator
               `((:a :location)
                 (:above ,(location-designator
                           `((:a :location)
                             (:in :sorting-basket)))))))))
     desig)
    (roslisp-beasty:make-default-joint-goal
     (lookat-sorting-basket-config) (desig-prop-value desig :sim)))
   (and
    (desig-prop-value-p desig :an :action)
    (desig-prop-value-p desig :to :see)
    (desig-descr-equal
     (desig-prop-value desig :obj)
     (object-designator '((:an :object)(:type :pickup-zone))))
    (alexandria:when-let ((distance (desig-prop-value desig :distance))
                          (sim-p (desig-prop-value desig :sim)))
      (roslisp-beasty:make-default-joint-goal
       (lookat-pickup-config distance) sim-p)))))

(defun infer-grasp-motion-goal (demo-handle desig)
  (and
   (desig-prop-value-p desig :an :action)
   (desig-prop-value-p desig :to :reach)
   (not (desig-prop-value desig :at))
   (alexandria:when-let*
       ((obj (desig-prop-value desig :obj))
        (goal-pose-stamped (infer-object-grasping-pose-stamped obj))
        (beasty-cartesian-goal (gripper-at-pose-stamped-msg
                                demo-handle goal-pose-stamped)))
     (roslisp-beasty:make-default-cartesian-goal beasty-cartesian-goal (desig-prop-value desig :sim)))))

(defun infer-object-grasping-offset (desig)
  (declare (ignore desig))
  ;; TODO: make this smart
  (cl-transforms:make-transform
   (cl-transforms:make-identity-vector)
   (cl-transforms:q*
    (cl-transforms:axis-angle->quaternion
     (cl-transforms:make-3d-vector 1 0 0) pi)
    (cl-transforms:axis-angle->quaternion
     (cl-transforms:make-3d-vector 0 0 1) (/ pi 2.0)))))

(defun infer-object-grasping-pose-stamped (desig)
  (alexandria:when-let*
      ((obj-pose-stamped-msg (infer-object-pose desig))
       (obj-grasping-offset (infer-object-grasping-offset desig)))
    (with-fields (header pose) obj-pose-stamped-msg
      (make-msg
       "geometry_msgs/PoseStamped"
       :header header
       :pose (transform->pose-msg
              (cl-transforms:transform*
               (pose-msg->transform pose)
               obj-grasping-offset))))))

(defun infer-slot-pose-stamped (slot-id)
  (declare (ignore slot-id))
  ;; TODO: make me smart
  (make-msg
   "geometry_msgs/PoseStamped"
   (:frame_id :header) "sorting_basket"
   (:x :position :pose) 0.25
   (:z :position :pose) 0.02
   (:w :orientation :pose) 1.0))
  
(defun infer-put-down-pose-stamped (object location)
  (alexandria:when-let*
      ((put-down-pose-stamped-msg (infer-location-pose location))
       (obj-grasping-offset (infer-object-grasping-offset object)))
    (with-fields (header pose) put-down-pose-stamped-msg
      (make-msg
       "geometry_msgs/PoseStamped"
       :header header
       :pose (transform->pose-msg
              (cl-transforms:transform*
               (pose-msg->transform pose)
               obj-grasping-offset))))))

(defun gripper-at-pose-stamped-msg (demo-handle pose-stamped-msg)
  (alexandria:when-let*
      ((tf (getf demo-handle :tf-listener))
       (goal-in-base
        (cl-tf:pose->transform
         (tf2-transform-pose-stamped-msg
          tf pose-stamped-msg "arm_base_link")))
       (inverse-gripper-offset
        (cl-tf2:transform
         (tf2-lookup
          tf "gripper_tool_frame" "arm_flange_link"))))
    (cl-transforms:transform* goal-in-base inverse-gripper-offset)))

(defun infer-put-down-motion-goal (demo-handle desig)
  (and
   (desig-prop-value-p desig :an :action)
   (desig-prop-value-p desig :to :reach)
   (alexandria:when-let*
       ((sim-p (desig-prop-value desig :sim))
        (loc (desig-prop-value desig :at))
        (obj (desig-prop-value desig :obj))
        (put-down-pose-stamped (infer-put-down-pose-stamped obj loc))
        (goal-pose-stamped (gripper-at-pose-stamped-msg demo-handle put-down-pose-stamped)))
     (roslisp-beasty:make-default-cartesian-goal goal-pose-stamped sim-p))))
                          
(defun infer-gripper-goal (desig)
  (or
   (infer-gripper-open-goal desig)
   (infer-gripper-close-goal desig)
   (infer-gripper-release-goal desig)
   (cpl:fail "Could not resolve: ~a" desig)))

(defun infer-gripper-close-goal (desig)
  (and
   (desig-prop-value-p desig :an :action)
   (desig-prop-value-p desig :to :clamp)
   (desig-prop-value-p desig :body-part :gripper)
   ;; TODO: more about objects?
   (list
    cram-wsg50:*wsg50-closed-width*
    cram-wsg50:*default-speed*
    cram-wsg50:*default-force*)))

(defun infer-gripper-open-goal (desig)
  (and
   (desig-prop-value-p desig :an :action)
   (desig-prop-value-p desig :to :open)
   (desig-prop-value-p desig :body-part :gripper)
   ;; TODO: more about objects?
   (list
    cram-wsg50:*wsg50-open-width*
    cram-wsg50:*default-speed*
    cram-wsg50:*default-force*)))

(defun infer-gripper-release-goal (desig)
  (and
   (desig-prop-value-p desig :an :action)
   (desig-prop-value-p desig :to :release)
   (desig-prop-value desig :obj)
   ;; TODO: more about objects?
   (list
    cram-wsg50:*wsg50-open-width*
    cram-wsg50:*default-speed*
    cram-wsg50:*default-force*)))

;;;
;;; MERE UTILS
;;;

(defun infer-object-pose (desig)
  (and
   (desig-prop-value-p desig :an :object)
   (infer-location-pose (desig-prop-value desig :at))))

(defun infer-location-pose (desig)
  (and
   (desig-prop-value-p desig :a :location)
   (desig-prop-value desig :pose)))

(defun infer-object-transform (desig &optional (postfix ""))
  (declare (type string postfix))
  (alexandria:when-let ((type-keyword (desig-prop-value desig :type))
                        (pose-stamped (infer-object-pose desig)))
    (pose-stamped-msg->transform-stamped-msg pose-stamped (concatenate 'string (symbol-name type-keyword) postfix))))
