#!/bin/bash
set -e

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -f|--file)
    export FILE_TO_UPGRADE="$2"
    shift # past argument
    shift # past value
    ;;
    -h|--help|*)
    echo "$0 -f(--file) <filetoupgrade>"
    exit 0
    ;;
esac
done

export FILE_TO_UPGRADE=${FILE_TO_UPGRADE:-"/var/lib/rancher/k3s/server/manifests/teknoir.yaml"}
echo "FILE_TO_UPGRADE=${FILE_TO_UPGRADE}"

# Check if already upgraded
if [ $(grep -c "CustomResourceDefinition" ${FILE_TO_UPGRADE}) -ne 0 ]; then
  echo "Already upgraded"
  exit 0
fi

echo "Now upgrading to TOEv2"

AR_SECRET=$(yq e 'select(.kind == "Secret") | select(.metadata.name == "artifact-registry-secret") | select(.metadata.namespace == "default") | .' ${FILE_TO_UPGRADE})
_AR_DOCKER_SECRET=$(echo "${AR_SECRET}" | yq e '.data.".dockerconfigjson"' -)
TOE_DEPLOYMENT=$(yq e 'select(.kind == "Deployment") | select(.metadata.name == "toe") | .' ${FILE_TO_UPGRADE})
_GCP_PROJECT=$(echo "${TOE_DEPLOYMENT}" | yq e '.spec.template.spec.containers[] | select(.name == "toe") | .env[] | select(.name == "TOE_PROJECT") | .value' -)
_DEVICE_ID=$(echo "${TOE_DEPLOYMENT}" | yq e '.spec.template.spec.containers[] | select(.name == "toe") | .env[] | select(.name == "TOE_DEVICE") | .value' -)
_IOT_REGISTRY=$(echo "${TOE_DEPLOYMENT}" | yq e '.spec.template.spec.containers[] | select(.name == "toe") | .env[] | select(.name == "TOE_IOT_REGISTRY") | .value' -)

#echo "_AR_DOCKER_SECRET=${_AR_DOCKER_SECRET}"
#echo "_GCP_PROJECT=${_GCP_PROJECT}"
#echo "_DEVICE_ID=${_DEVICE_ID}"
#echo "_IOT_REGISTRY=${_IOT_REGISTRY}"

# Check that vars exist
if [ -z ${_GCP_PROJECT+x} ]; then fatal "_GCP_PROJECT is unset"; fi
if [ -z ${_IOT_REGISTRY+x} ]; then fatal "_IOT_REGISTRY is unset"; fi
if [ -z ${_DEVICE_ID+x} ]; then fatal "_DEVICE_ID is unset"; fi
if [ -z ${_AR_DOCKER_SECRET+x} ]; then fatal "_AR_DOCKER_SECRET is unset"; fi

chmod 440 /etc/teknoir/rsa_private.pem
chown 65532:root /etc/teknoir/rsa_private.pem

# THIS IS SAME AS templates/07_teknoir_manifests.yaml.template
tee ${FILE_TO_UPGRADE}.new > /dev/null << EOL
---
apiVersion: v1
kind: Secret
metadata:
  name: artifact-registry-secret
  namespace: kube-system
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: "${_AR_DOCKER_SECRET}"

---
apiVersion: v1
kind: Secret
metadata:
  name: artifact-registry-secret
  namespace: default
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: "${_AR_DOCKER_SECRET}"

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: default
imagePullSecrets:
- name: artifact-registry-secret

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: kube-system
imagePullSecrets:
- name: artifact-registry-secret

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority-mqtt
  namespace: kube-system
value: 900000000
globalDefault: false
description: "This priority class should be used for mqtt service pods only."

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mqtt
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mqtt
  template:
    metadata:
      labels:
        app: mqtt
    spec:
      priorityClassName: high-priority-mqtt
      initContainers:
        - name: init
          image: busybox:1.28
          command: ['sh', '-c', 'echo>/mosquitto/shadow/passwd']
          volumeMounts:
            - name: shadow-volume
              mountPath: "/mosquitto/shadow"
      containers:
        - name: mqtt
          image: eclipse-mosquitto:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 1883
          resources:
            requests:
              memory: "32Mi"
              cpu: "20m"
            limits:
              memory: "128Mi"
              cpu: "1500m"
          volumeMounts:
            - name: data-volume
              mountPath: "/mosquitto/data"
            - name: config-volume
              mountPath: "/mosquitto/config"
            - name: shadow-volume
              mountPath: "/mosquitto/shadow"
      volumes:
        - name: data-volume
          hostPath:
            path: "/mosquitto/data"
        - name: config-volume
          configMap:
            name: mqtt-config
        - name: shadow-volume
          hostPath:
            path: "/mosquitto/shadow"

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mqtt-config
  namespace: kube-system
data:
  mosquitto.conf: |
    listener 1883
    protocol mqtt
    allow_anonymous true
    persistence true
    persistence_location /mosquitto/data
    persistent_client_expiration 2m
    password_file /mosquitto/shadow/passwd
    log_dest stdout
    log_timestamp true
    log_timestamp_format %Y-%m-%dT%H:%M:%S
    log_type error
    log_type warning
    log_type notice
    log_type information
    log_type subscribe
    log_type unsubscribe

---
apiVersion: v1
kind: Service
metadata:
  name: mqtt
  namespace: kube-system
spec:
  selector:
    app: mqtt
  ports:
    - protocol: TCP
      port: 1883
      targetPort: 1883

---
apiVersion: v1
kind: Service
metadata:
  name: mqtt-localhost
  namespace: kube-system
spec:
  type: NodePort
  ports:
    - nodePort: 31883
      port: 1883
      protocol: TCP
      targetPort: 1883
  selector:
    app: mqtt

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority-toe
  namespace: kube-system
value: 1000000000
globalDefault: false
description: "This priority class should be used for toe service pods only."

---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.12.0
  name: toes.teknoir.org
spec:
  group: teknoir.org
  names:
    kind: TOE
    listKind: TOEList
    plural: toes
    singular: toe
  scope: Cluster
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        description: TOE is the Schema for the toes API
        properties:
          apiVersion:
            description: 'APIVersion defines the versioned schema of this representation
              of an object. Servers should convert recognized schemas to the latest
              internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
            type: string
          kind:
            description: 'Kind is a string value representing the REST resource this
              object represents. Servers may infer this from the endpoint the client
              submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
            type: string
          metadata:
            type: object
          spec:
            description: TOESpec defines the desired state of TOE
            properties:
              config:
                description: ConfigObjectList contains a list of objects
                properties:
                  apiVersion:
                    description: 'APIVersion defines the versioned schema of this
                      representation of an object. Servers should convert recognized
                      schemas to the latest internal value, and may reject unrecognized
                      values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
                    type: string
                  items:
                    description: items contains each of the included items.
                    items:
                      description: ConfigObject is a generic representation of any
                        object with ObjectMeta. It allows clients to get access to
                        a particular ObjectMeta schema without knowing the details
                        of the version.
                      properties:
                        apiVersion:
                          description: 'APIVersion defines the versioned schema of
                            this representation of an object. Servers should convert
                            recognized schemas to the latest internal value, and may
                            reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
                          type: string
                        binaryData:
                          additionalProperties:
                            format: byte
                            type: string
                          description: BinaryData contains the binary data. Each key
                            must consist of alphanumeric characters, '-', '_' or '.'.
                            BinaryData can contain byte sequences that are not in
                            the UTF-8 range. The keys stored in BinaryData must not
                            overlap with the ones in the Data field, this is enforced
                            during validation process. Using this field will require
                            1.10+ apiserver and kubelet.
                          type: object
                        data:
                          additionalProperties:
                            type: string
                          description: Data contains the configuration data. Each
                            key must consist of alphanumeric characters, '-', '_'
                            or '.'. Values with non-UTF-8 byte sequences must use
                            the BinaryData field. The keys stored in Data must not
                            overlap with the keys in the BinaryData field, this is
                            enforced during validation process.
                          type: object
                        kind:
                          description: 'Kind is a string value representing the REST
                            resource this object represents. Servers may infer this
                            from the endpoint the client submits requests to. Cannot
                            be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                          type: string
                        metadata:
                          description: "ObjectMeta is metadata that all persisted
                            resources must have, which includes all objects users
                            must create. This is a copy of customizable fields from
                            metav1.ObjectMeta. \n ObjectMeta is embedded in 'Machine.Spec',
                            'MachineDeployment.Template' and 'MachineSet.Template',
                            which are not top-level Kubernetes objects. Given that
                            metav1.ObjectMeta has lots of special cases and read-only
                            fields which end up in the generated CRD validation, having
                            it as a subset simplifies the API and some issues that
                            can impact user experience. \n During the [upgrade to
                            controller-tools@v2](https://github.com/kubernetes-sigs/cluster-api/pull/1054)
                            for v1alpha2, we noticed a failure would occur running
                            Cluster API test suite against the new CRDs, specifically
                            'spec.metadata.creationTimestamp in body must be of type
                            string: \"null\"'. The investigation showed that 'controller-tools@v2'
                            behaves differently than its previous version when handling
                            types from [metav1](k8s.io/apimachinery/pkg/apis/meta/v1)
                            package. \n In more details, we found that embedded (non-top
                            level) types that embedded 'metav1.ObjectMeta' had validation
                            properties, including for 'creationTimestamp' (metav1.Time).
                            The 'metav1.Time' type specifies a custom json marshaller
                            that, when IsZero() is true, returns 'null' which breaks
                            validation because the field isn't marked as nullable.
                            \n In future versions, controller-tools@v2 might allow
                            overriding the type and validation for embedded types.
                            When that happens, this hack should be revisited."
                          properties:
                            annotations:
                              additionalProperties:
                                type: string
                              description: 'Annotations is an unstructured key value
                                map stored with a resource that may be set by external
                                tools to store and retrieve arbitrary metadata. They
                                are not queryable and should be preserved when modifying
                                objects. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations'
                              type: object
                            creationTimestamp:
                              description: "CreationTimestamp is a timestamp representing
                                the server time when this object was created. It is
                                not guaranteed to be set in happens-before order across
                                separate operations. Clients may not set this value.
                                It is represented in RFC3339 form and is in UTC. \n
                                Populated by the system. Read-only. Null for lists.
                                More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata"
                              format: date-time
                              type: string
                            deletionGracePeriodSeconds:
                              description: Number of seconds allowed for this object
                                to gracefully terminate before it will be removed
                                from the system. Only set when deletionTimestamp is
                                also set. May only be shortened. Read-only.
                              format: int64
                              type: integer
                            deletionTimestamp:
                              description: "DeletionTimestamp is RFC 3339 date and
                                time at which this resource will be deleted. This
                                field is set by the server when a graceful deletion
                                is requested by the user, and is not directly settable
                                by a client. The resource is expected to be deleted
                                (no longer visible from resource lists, and not reachable
                                by name) after the time in this field, once the finalizers
                                list is empty. As long as the finalizers list contains
                                items, deletion is blocked. Once the deletionTimestamp
                                is set, this value may not be unset or be set further
                                into the future, although it may be shortened or the
                                resource may be deleted prior to this time. For example,
                                a user may request that a pod is deleted in 30 seconds.
                                The Kubelet will react by sending a graceful termination
                                signal to the containers in the pod. After that 30
                                seconds, the Kubelet will send a hard termination
                                signal (SIGKILL) to the container and after cleanup,
                                remove the pod from the API. In the presence of network
                                partitions, this object may still exist after this
                                timestamp, until an administrator or automated process
                                can determine the resource is fully terminated. If
                                not set, graceful deletion of the object has not been
                                requested. \n Populated by the system when a graceful
                                deletion is requested. Read-only. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata"
                              format: date-time
                              type: string
                            finalizers:
                              description: Must be empty before the object is deleted
                                from the registry. Each entry is an identifier for
                                the responsible component that will remove the entry
                                from the list. If the deletionTimestamp of the object
                                is non-nil, entries in this list can only be removed.
                                Finalizers may be processed and removed in any order.  Order
                                is NOT enforced because it introduces significant
                                risk of stuck finalizers. finalizers is a shared field,
                                any actor with permission can reorder it. If the finalizer
                                list is processed in order, then this can lead to
                                a situation in which the component responsible for
                                the first finalizer in the list is waiting for a signal
                                (field value, external system, or other) produced
                                by a component responsible for a finalizer later in
                                the list, resulting in a deadlock. Without enforced
                                ordering finalizers are free to order amongst themselves
                                and are not vulnerable to ordering changes in the
                                list.
                              items:
                                type: string
                              type: array
                            generateName:
                              description: "GenerateName is an optional prefix, used
                                by the server, to generate a unique name ONLY IF the
                                Name field has not been provided. If this field is
                                used, the name returned to the client will be different
                                than the name passed. This value will also be combined
                                with a unique suffix. The provided value has the same
                                validation rules as the Name field, and may be truncated
                                by the length of the suffix required to make the value
                                unique on the server. \n If this field is specified
                                and the generated name exists, the server will return
                                a 409. \n Applied only if Name is not specified. More
                                info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#idempotency"
                              type: string
                            generation:
                              description: A sequence number representing a specific
                                generation of the desired state. Populated by the
                                system. Read-only.
                              format: int64
                              type: integer
                            labels:
                              additionalProperties:
                                type: string
                              description: 'Map of string keys and values that can
                                be used to organize and categorize (scope and select)
                                objects. May match selectors of replication controllers
                                and services. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels'
                              type: object
                            managedFields:
                              description: ManagedFields maps workflow-id and version
                                to the set of fields that are managed by that workflow.
                                This is mostly for internal housekeeping, and users
                                typically shouldn't need to set or understand this
                                field. A workflow can be the user's name, a controller's
                                name, or the name of a specific apply path like "ci-cd".
                                The set of fields is always in the version that the
                                workflow used when modifying the object.
                              items:
                                description: ManagedFieldsEntry is a workflow-id,
                                  a FieldSet and the group version of the resource
                                  that the fieldset applies to.
                                properties:
                                  apiVersion:
                                    description: APIVersion defines the version of
                                      this resource that this field set applies to.
                                      The format is "group/version" just like the
                                      top-level APIVersion field. It is necessary
                                      to track the version of a field set because
                                      it cannot be automatically converted.
                                    type: string
                                  fieldsType:
                                    description: 'FieldsType is the discriminator
                                      for the different fields format and version.
                                      There is currently only one possible value:
                                      "FieldsV1"'
                                    type: string
                                  fieldsV1:
                                    description: FieldsV1 holds the first JSON version
                                      format as described in the "FieldsV1" type.
                                    type: object
                                  manager:
                                    description: Manager is an identifier of the workflow
                                      managing these fields.
                                    type: string
                                  operation:
                                    description: Operation is the type of operation
                                      which lead to this ManagedFieldsEntry being
                                      created. The only valid values for this field
                                      are 'Apply' and 'Update'.
                                    type: string
                                  subresource:
                                    description: Subresource is the name of the subresource
                                      used to update that object, or empty string
                                      if the object was updated through the main resource.
                                      The value of this field is used to distinguish
                                      between managers, even if they share the same
                                      name. For example, a status update will be distinct
                                      from a regular update using the same manager
                                      name. Note that the APIVersion field is not
                                      related to the Subresource field and it always
                                      corresponds to the version of the main resource.
                                    type: string
                                  time:
                                    description: Time is the timestamp of when the
                                      ManagedFields entry was added. The timestamp
                                      will also be updated if a field is added, the
                                      manager changes any of the owned fields value
                                      or removes a field. The timestamp does not update
                                      when a field is removed from the entry because
                                      another manager took it over.
                                    format: date-time
                                    type: string
                                type: object
                              type: array
                            name:
                              description: 'Name must be unique within a namespace.
                                Is required when creating resources, although some
                                resources may allow a client to request the generation
                                of an appropriate name automatically. Name is primarily
                                intended for creation idempotence and configuration
                                definition. Cannot be updated. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names#names'
                              type: string
                            namespace:
                              description: "Namespace defines the space within which
                                each name must be unique. An empty namespace is equivalent
                                to the \"default\" namespace, but \"default\" is the
                                canonical representation. Not all objects are required
                                to be scoped to a namespace - the value of this field
                                for those objects will be empty. \n Must be a DNS_LABEL.
                                Cannot be updated. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces"
                              type: string
                            ownerReferences:
                              description: List of objects depended by this object.
                                If ALL objects in the list have been deleted, this
                                object will be garbage collected. If this object is
                                managed by a controller, then an entry in this list
                                will point to this controller, with the controller
                                field set to true. There cannot be more than one managing
                                controller.
                              items:
                                description: OwnerReference contains enough information
                                  to let you identify an owning object. An owning
                                  object must be in the same namespace as the dependent,
                                  or be cluster-scoped, so there is no namespace field.
                                properties:
                                  apiVersion:
                                    description: API version of the referent.
                                    type: string
                                  blockOwnerDeletion:
                                    description: If true, AND if the owner has the
                                      "foregroundDeletion" finalizer, then the owner
                                      cannot be deleted from the key-value store until
                                      this reference is removed. See https://kubernetes.io/docs/concepts/architecture/garbage-collection/#foreground-deletion
                                      for how the garbage collector interacts with
                                      this field and enforces the foreground deletion.
                                      Defaults to false. To set this field, a user
                                      needs "delete" permission of the owner, otherwise
                                      422 (Unprocessable Entity) will be returned.
                                    type: boolean
                                  controller:
                                    description: If true, this reference points to
                                      the managing controller.
                                    type: boolean
                                  kind:
                                    description: 'Kind of the referent. More info:
                                      https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                                    type: string
                                  name:
                                    description: 'Name of the referent. More info:
                                      https://kubernetes.io/docs/concepts/overview/working-with-objects/names#names'
                                    type: string
                                  uid:
                                    description: 'UID of the referent. More info:
                                      https://kubernetes.io/docs/concepts/overview/working-with-objects/names#uids'
                                    type: string
                                required:
                                - apiVersion
                                - kind
                                - name
                                - uid
                                type: object
                                x-kubernetes-map-type: atomic
                              type: array
                            resourceVersion:
                              description: "An opaque value that represents the internal
                                version of this object that can be used by clients
                                to determine when objects have changed. May be used
                                for optimistic concurrency, change detection, and
                                the watch operation on a resource or set of resources.
                                Clients must treat these values as opaque and passed
                                unmodified back to the server. They may only be valid
                                for a particular resource or set of resources. \n
                                Populated by the system. Read-only. Value must be
                                treated as opaque by clients and . More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#concurrency-control-and-consistency"
                              type: string
                            selfLink:
                              description: 'Deprecated: selfLink is a legacy read-only
                                field that is no longer populated by the system.'
                              type: string
                            uid:
                              description: "UID is the unique in time and space value
                                for this object. It is typically generated by the
                                server on successful creation of a resource and is
                                not allowed to change on PUT operations. \n Populated
                                by the system. Read-only. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names#uids"
                              type: string
                          type: object
                        spec:
                          description: Specification of the desired behavior of the
                            object.
                          x-kubernetes-preserve-unknown-fields: true
                        status:
                          description: Specification of the desired behavior of the
                            object.
                          x-kubernetes-preserve-unknown-fields: true
                      required:
                      - metadata
                      type: object
                    type: array
                  kind:
                    description: 'Kind is a string value representing the REST resource
                      this object represents. Servers may infer this from the endpoint
                      the client submits requests to. Cannot be updated. In CamelCase.
                      More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                    type: string
                  metadata:
                    description: 'Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                    properties:
                      continue:
                        description: continue may be set if the user set a limit on
                          the number of items returned, and indicates that the server
                          has more data available. The value is opaque and may be
                          used to issue another request to the endpoint that served
                          this list to retrieve the next set of available objects.
                          Continuing a consistent list may not be possible if the
                          server configuration has changed or more than a few minutes
                          have passed. The resourceVersion field returned when using
                          this continue value will be identical to the value in the
                          first response, unless you have received this token from
                          an error message.
                        type: string
                      remainingItemCount:
                        description: remainingItemCount is the number of subsequent
                          items in the list which are not included in this list response.
                          If the list request contained label or field selectors,
                          then the number of remaining items is unknown and the field
                          will be left unset and omitted during serialization. If
                          the list is complete (either because it is not chunking
                          or because this is the last chunk), then there are no more
                          remaining items and this field will be left unset and omitted
                          during serialization. Servers older than v1.15 do not set
                          this field. The intended use of the remainingItemCount is
                          *estimating* the size of a collection. Clients should not
                          rely on the remainingItemCount to be set or to be exact.
                        format: int64
                        type: integer
                      resourceVersion:
                        description: 'String that identifies the server''s internal
                          version of this object that can be used by clients to determine
                          when objects have changed. Value must be treated as opaque
                          by clients and passed unmodified back to the server. Populated
                          by the system. Read-only. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#concurrency-control-and-consistency'
                        type: string
                      selfLink:
                        description: 'Deprecated: selfLink is a legacy read-only field
                          that is no longer populated by the system.'
                        type: string
                    type: object
                required:
                - items
                type: object
                x-kubernetes-preserve-unknown-fields: true
            type: object
          status:
            description: TOEStatus defines the observed state of TOE
            properties:
              last_applied_config:
                description: ConfigObjectList contains a list of objects
                properties:
                  apiVersion:
                    description: 'APIVersion defines the versioned schema of this
                      representation of an object. Servers should convert recognized
                      schemas to the latest internal value, and may reject unrecognized
                      values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
                    type: string
                  items:
                    description: items contains each of the included items.
                    items:
                      description: ConfigObject is a generic representation of any
                        object with ObjectMeta. It allows clients to get access to
                        a particular ObjectMeta schema without knowing the details
                        of the version.
                      properties:
                        apiVersion:
                          description: 'APIVersion defines the versioned schema of
                            this representation of an object. Servers should convert
                            recognized schemas to the latest internal value, and may
                            reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
                          type: string
                        binaryData:
                          additionalProperties:
                            format: byte
                            type: string
                          description: BinaryData contains the binary data. Each key
                            must consist of alphanumeric characters, '-', '_' or '.'.
                            BinaryData can contain byte sequences that are not in
                            the UTF-8 range. The keys stored in BinaryData must not
                            overlap with the ones in the Data field, this is enforced
                            during validation process. Using this field will require
                            1.10+ apiserver and kubelet.
                          type: object
                        data:
                          additionalProperties:
                            type: string
                          description: Data contains the configuration data. Each
                            key must consist of alphanumeric characters, '-', '_'
                            or '.'. Values with non-UTF-8 byte sequences must use
                            the BinaryData field. The keys stored in Data must not
                            overlap with the keys in the BinaryData field, this is
                            enforced during validation process.
                          type: object
                        kind:
                          description: 'Kind is a string value representing the REST
                            resource this object represents. Servers may infer this
                            from the endpoint the client submits requests to. Cannot
                            be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                          type: string
                        metadata:
                          description: "ObjectMeta is metadata that all persisted
                            resources must have, which includes all objects users
                            must create. This is a copy of customizable fields from
                            metav1.ObjectMeta. \n ObjectMeta is embedded in 'Machine.Spec',
                            'MachineDeployment.Template' and 'MachineSet.Template',
                            which are not top-level Kubernetes objects. Given that
                            metav1.ObjectMeta has lots of special cases and read-only
                            fields which end up in the generated CRD validation, having
                            it as a subset simplifies the API and some issues that
                            can impact user experience. \n During the [upgrade to
                            controller-tools@v2](https://github.com/kubernetes-sigs/cluster-api/pull/1054)
                            for v1alpha2, we noticed a failure would occur running
                            Cluster API test suite against the new CRDs, specifically
                            'spec.metadata.creationTimestamp in body must be of type
                            string: \"null\"'. The investigation showed that 'controller-tools@v2'
                            behaves differently than its previous version when handling
                            types from [metav1](k8s.io/apimachinery/pkg/apis/meta/v1)
                            package. \n In more details, we found that embedded (non-top
                            level) types that embedded 'metav1.ObjectMeta' had validation
                            properties, including for 'creationTimestamp' (metav1.Time).
                            The 'metav1.Time' type specifies a custom json marshaller
                            that, when IsZero() is true, returns 'null' which breaks
                            validation because the field isn't marked as nullable.
                            \n In future versions, controller-tools@v2 might allow
                            overriding the type and validation for embedded types.
                            When that happens, this hack should be revisited."
                          properties:
                            annotations:
                              additionalProperties:
                                type: string
                              description: 'Annotations is an unstructured key value
                                map stored with a resource that may be set by external
                                tools to store and retrieve arbitrary metadata. They
                                are not queryable and should be preserved when modifying
                                objects. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations'
                              type: object
                            creationTimestamp:
                              description: "CreationTimestamp is a timestamp representing
                                the server time when this object was created. It is
                                not guaranteed to be set in happens-before order across
                                separate operations. Clients may not set this value.
                                It is represented in RFC3339 form and is in UTC. \n
                                Populated by the system. Read-only. Null for lists.
                                More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata"
                              format: date-time
                              type: string
                            deletionGracePeriodSeconds:
                              description: Number of seconds allowed for this object
                                to gracefully terminate before it will be removed
                                from the system. Only set when deletionTimestamp is
                                also set. May only be shortened. Read-only.
                              format: int64
                              type: integer
                            deletionTimestamp:
                              description: "DeletionTimestamp is RFC 3339 date and
                                time at which this resource will be deleted. This
                                field is set by the server when a graceful deletion
                                is requested by the user, and is not directly settable
                                by a client. The resource is expected to be deleted
                                (no longer visible from resource lists, and not reachable
                                by name) after the time in this field, once the finalizers
                                list is empty. As long as the finalizers list contains
                                items, deletion is blocked. Once the deletionTimestamp
                                is set, this value may not be unset or be set further
                                into the future, although it may be shortened or the
                                resource may be deleted prior to this time. For example,
                                a user may request that a pod is deleted in 30 seconds.
                                The Kubelet will react by sending a graceful termination
                                signal to the containers in the pod. After that 30
                                seconds, the Kubelet will send a hard termination
                                signal (SIGKILL) to the container and after cleanup,
                                remove the pod from the API. In the presence of network
                                partitions, this object may still exist after this
                                timestamp, until an administrator or automated process
                                can determine the resource is fully terminated. If
                                not set, graceful deletion of the object has not been
                                requested. \n Populated by the system when a graceful
                                deletion is requested. Read-only. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata"
                              format: date-time
                              type: string
                            finalizers:
                              description: Must be empty before the object is deleted
                                from the registry. Each entry is an identifier for
                                the responsible component that will remove the entry
                                from the list. If the deletionTimestamp of the object
                                is non-nil, entries in this list can only be removed.
                                Finalizers may be processed and removed in any order.  Order
                                is NOT enforced because it introduces significant
                                risk of stuck finalizers. finalizers is a shared field,
                                any actor with permission can reorder it. If the finalizer
                                list is processed in order, then this can lead to
                                a situation in which the component responsible for
                                the first finalizer in the list is waiting for a signal
                                (field value, external system, or other) produced
                                by a component responsible for a finalizer later in
                                the list, resulting in a deadlock. Without enforced
                                ordering finalizers are free to order amongst themselves
                                and are not vulnerable to ordering changes in the
                                list.
                              items:
                                type: string
                              type: array
                            generateName:
                              description: "GenerateName is an optional prefix, used
                                by the server, to generate a unique name ONLY IF the
                                Name field has not been provided. If this field is
                                used, the name returned to the client will be different
                                than the name passed. This value will also be combined
                                with a unique suffix. The provided value has the same
                                validation rules as the Name field, and may be truncated
                                by the length of the suffix required to make the value
                                unique on the server. \n If this field is specified
                                and the generated name exists, the server will return
                                a 409. \n Applied only if Name is not specified. More
                                info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#idempotency"
                              type: string
                            generation:
                              description: A sequence number representing a specific
                                generation of the desired state. Populated by the
                                system. Read-only.
                              format: int64
                              type: integer
                            labels:
                              additionalProperties:
                                type: string
                              description: 'Map of string keys and values that can
                                be used to organize and categorize (scope and select)
                                objects. May match selectors of replication controllers
                                and services. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels'
                              type: object
                            managedFields:
                              description: ManagedFields maps workflow-id and version
                                to the set of fields that are managed by that workflow.
                                This is mostly for internal housekeeping, and users
                                typically shouldn't need to set or understand this
                                field. A workflow can be the user's name, a controller's
                                name, or the name of a specific apply path like "ci-cd".
                                The set of fields is always in the version that the
                                workflow used when modifying the object.
                              items:
                                description: ManagedFieldsEntry is a workflow-id,
                                  a FieldSet and the group version of the resource
                                  that the fieldset applies to.
                                properties:
                                  apiVersion:
                                    description: APIVersion defines the version of
                                      this resource that this field set applies to.
                                      The format is "group/version" just like the
                                      top-level APIVersion field. It is necessary
                                      to track the version of a field set because
                                      it cannot be automatically converted.
                                    type: string
                                  fieldsType:
                                    description: 'FieldsType is the discriminator
                                      for the different fields format and version.
                                      There is currently only one possible value:
                                      "FieldsV1"'
                                    type: string
                                  fieldsV1:
                                    description: FieldsV1 holds the first JSON version
                                      format as described in the "FieldsV1" type.
                                    type: object
                                  manager:
                                    description: Manager is an identifier of the workflow
                                      managing these fields.
                                    type: string
                                  operation:
                                    description: Operation is the type of operation
                                      which lead to this ManagedFieldsEntry being
                                      created. The only valid values for this field
                                      are 'Apply' and 'Update'.
                                    type: string
                                  subresource:
                                    description: Subresource is the name of the subresource
                                      used to update that object, or empty string
                                      if the object was updated through the main resource.
                                      The value of this field is used to distinguish
                                      between managers, even if they share the same
                                      name. For example, a status update will be distinct
                                      from a regular update using the same manager
                                      name. Note that the APIVersion field is not
                                      related to the Subresource field and it always
                                      corresponds to the version of the main resource.
                                    type: string
                                  time:
                                    description: Time is the timestamp of when the
                                      ManagedFields entry was added. The timestamp
                                      will also be updated if a field is added, the
                                      manager changes any of the owned fields value
                                      or removes a field. The timestamp does not update
                                      when a field is removed from the entry because
                                      another manager took it over.
                                    format: date-time
                                    type: string
                                type: object
                              type: array
                            name:
                              description: 'Name must be unique within a namespace.
                                Is required when creating resources, although some
                                resources may allow a client to request the generation
                                of an appropriate name automatically. Name is primarily
                                intended for creation idempotence and configuration
                                definition. Cannot be updated. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names#names'
                              type: string
                            namespace:
                              description: "Namespace defines the space within which
                                each name must be unique. An empty namespace is equivalent
                                to the \"default\" namespace, but \"default\" is the
                                canonical representation. Not all objects are required
                                to be scoped to a namespace - the value of this field
                                for those objects will be empty. \n Must be a DNS_LABEL.
                                Cannot be updated. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces"
                              type: string
                            ownerReferences:
                              description: List of objects depended by this object.
                                If ALL objects in the list have been deleted, this
                                object will be garbage collected. If this object is
                                managed by a controller, then an entry in this list
                                will point to this controller, with the controller
                                field set to true. There cannot be more than one managing
                                controller.
                              items:
                                description: OwnerReference contains enough information
                                  to let you identify an owning object. An owning
                                  object must be in the same namespace as the dependent,
                                  or be cluster-scoped, so there is no namespace field.
                                properties:
                                  apiVersion:
                                    description: API version of the referent.
                                    type: string
                                  blockOwnerDeletion:
                                    description: If true, AND if the owner has the
                                      "foregroundDeletion" finalizer, then the owner
                                      cannot be deleted from the key-value store until
                                      this reference is removed. See https://kubernetes.io/docs/concepts/architecture/garbage-collection/#foreground-deletion
                                      for how the garbage collector interacts with
                                      this field and enforces the foreground deletion.
                                      Defaults to false. To set this field, a user
                                      needs "delete" permission of the owner, otherwise
                                      422 (Unprocessable Entity) will be returned.
                                    type: boolean
                                  controller:
                                    description: If true, this reference points to
                                      the managing controller.
                                    type: boolean
                                  kind:
                                    description: 'Kind of the referent. More info:
                                      https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                                    type: string
                                  name:
                                    description: 'Name of the referent. More info:
                                      https://kubernetes.io/docs/concepts/overview/working-with-objects/names#names'
                                    type: string
                                  uid:
                                    description: 'UID of the referent. More info:
                                      https://kubernetes.io/docs/concepts/overview/working-with-objects/names#uids'
                                    type: string
                                required:
                                - apiVersion
                                - kind
                                - name
                                - uid
                                type: object
                                x-kubernetes-map-type: atomic
                              type: array
                            resourceVersion:
                              description: "An opaque value that represents the internal
                                version of this object that can be used by clients
                                to determine when objects have changed. May be used
                                for optimistic concurrency, change detection, and
                                the watch operation on a resource or set of resources.
                                Clients must treat these values as opaque and passed
                                unmodified back to the server. They may only be valid
                                for a particular resource or set of resources. \n
                                Populated by the system. Read-only. Value must be
                                treated as opaque by clients and . More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#concurrency-control-and-consistency"
                              type: string
                            selfLink:
                              description: 'Deprecated: selfLink is a legacy read-only
                                field that is no longer populated by the system.'
                              type: string
                            uid:
                              description: "UID is the unique in time and space value
                                for this object. It is typically generated by the
                                server on successful creation of a resource and is
                                not allowed to change on PUT operations. \n Populated
                                by the system. Read-only. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names#uids"
                              type: string
                          type: object
                        spec:
                          description: Specification of the desired behavior of the
                            object.
                          x-kubernetes-preserve-unknown-fields: true
                        status:
                          description: Specification of the desired behavior of the
                            object.
                          x-kubernetes-preserve-unknown-fields: true
                      required:
                      - metadata
                      type: object
                    type: array
                  kind:
                    description: 'Kind is a string value representing the REST resource
                      this object represents. Servers may infer this from the endpoint
                      the client submits requests to. Cannot be updated. In CamelCase.
                      More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                    type: string
                  metadata:
                    description: 'Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                    properties:
                      continue:
                        description: continue may be set if the user set a limit on
                          the number of items returned, and indicates that the server
                          has more data available. The value is opaque and may be
                          used to issue another request to the endpoint that served
                          this list to retrieve the next set of available objects.
                          Continuing a consistent list may not be possible if the
                          server configuration has changed or more than a few minutes
                          have passed. The resourceVersion field returned when using
                          this continue value will be identical to the value in the
                          first response, unless you have received this token from
                          an error message.
                        type: string
                      remainingItemCount:
                        description: remainingItemCount is the number of subsequent
                          items in the list which are not included in this list response.
                          If the list request contained label or field selectors,
                          then the number of remaining items is unknown and the field
                          will be left unset and omitted during serialization. If
                          the list is complete (either because it is not chunking
                          or because this is the last chunk), then there are no more
                          remaining items and this field will be left unset and omitted
                          during serialization. Servers older than v1.15 do not set
                          this field. The intended use of the remainingItemCount is
                          *estimating* the size of a collection. Clients should not
                          rely on the remainingItemCount to be set or to be exact.
                        format: int64
                        type: integer
                      resourceVersion:
                        description: 'String that identifies the server''s internal
                          version of this object that can be used by clients to determine
                          when objects have changed. Value must be treated as opaque
                          by clients and passed unmodified back to the server. Populated
                          by the system. Read-only. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#concurrency-control-and-consistency'
                        type: string
                      selfLink:
                        description: 'Deprecated: selfLink is a legacy read-only field
                          that is no longer populated by the system.'
                        type: string
                    type: object
                required:
                - items
                type: object
                x-kubernetes-preserve-unknown-fields: true
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}

---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: controller-manager-sa
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: serviceaccount
    app.kubernetes.io/part-of: teknoir
  name: teknoir-controller-manager
  namespace: kube-system
imagePullSecrets:
- name: artifact-registry-secret

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: leader-election-role
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: role
    app.kubernetes.io/part-of: teknoir
  name: teknoir-leader-election-role
  namespace: kube-system
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: teknoir-manager-role
rules:
- apiGroups:
  - teknoir.org
  resources:
  - toes
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - teknoir.org
  resources:
  - toes/finalizers
  verbs:
  - update
- apiGroups:
  - teknoir.org
  resources:
  - toes/status
  verbs:
  - get
  - patch
  - update

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/component: kube-rbac-proxy
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: metrics-reader
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: clusterrole
    app.kubernetes.io/part-of: teknoir
  name: teknoir-metrics-reader
rules:
- nonResourceURLs:
  - /metrics
  verbs:
  - get

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/component: kube-rbac-proxy
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: proxy-role
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: clusterrole
    app.kubernetes.io/part-of: teknoir
  name: teknoir-proxy-role
rules:
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
- apiGroups:
  - authorization.k8s.io
  resources:
  - subjectaccessreviews
  verbs:
  - create

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: manager-rolebinding
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: clusterrolebinding
    app.kubernetes.io/part-of: teknoir
  name: teknoir-admin-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: teknoir-controller-manager
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: leader-election-rolebinding
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: rolebinding
    app.kubernetes.io/part-of: teknoir
  name: teknoir-leader-election-rolebinding
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: teknoir-leader-election-role
subjects:
- kind: ServiceAccount
  name: teknoir-controller-manager
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: manager-rolebinding
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: clusterrolebinding
    app.kubernetes.io/part-of: teknoir
  name: teknoir-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: teknoir-manager-role
subjects:
- kind: ServiceAccount
  name: teknoir-controller-manager
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/component: kube-rbac-proxy
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: proxy-rolebinding
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: clusterrolebinding
    app.kubernetes.io/part-of: teknoir
  name: teknoir-proxy-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: teknoir-proxy-role
subjects:
- kind: ServiceAccount
  name: teknoir-controller-manager
  namespace: kube-system

---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: kube-rbac-proxy
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: controller-manager-metrics-service
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: service
    app.kubernetes.io/part-of: teknoir
    control-plane: controller-manager
  name: toe-metrics-service
  namespace: kube-system
spec:
  ports:
  - name: https
    port: 8443
    protocol: TCP
    targetPort: https
  selector:
    control-plane: controller-manager

---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: manager
    app.kubernetes.io/created-by: teknoir
    app.kubernetes.io/instance: controller-manager
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: deployment
    app.kubernetes.io/part-of: teknoir
    control-plane: controller-manager
  name: toe
  namespace: kube-system
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        teknoir.org/app: toe
        app: toe
        control-plane: controller-manager
    spec:
      priorityClassName: high-priority-toe
      containers:
      - args:
        - --secure-listen-address=0.0.0.0:8443
        - --upstream=http://127.0.0.1:8080/
        - --logtostderr=true
        - --v=0
        image: gcr.io/kubebuilder/kube-rbac-proxy:v0.14.1
        name: ube-rbac-proxy
        ports:
        - containerPort: 8443
          name: https
          protocol: TCP
        resources:
          limits:
            cpu: 500m
            memory: 128Mi
          requests:
            cpu: 5m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      - args:
        - --health-probe-bind-address=:8081
        - --metrics-bind-address=127.0.0.1:8080
        env:
        - name: CLIENT_ID
          value: "${_DEVICE_ID}"
        - name: TOE_PROJECT
          value: "${_GCP_PROJECT}"
        - name: TOE_IOT_REGISTRY
          value: "${_IOT_REGISTRY}"
        - name: TOE_DEVICE
          value: "${_DEVICE_ID}"
        - name: TOE_CA_CERT
          value: "/etc/teknoir/roots.pem"
        - name: TOE_PRIVATE_KEY
          value: "/etc/teknoir/rsa_private.pem"
        volumeMounts:
        - name: toe-volume
          mountPath: /etc/teknoir
        command:
        - /manager
        image: gcr.io/teknoir/toe:toe_v2_state-5717319
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        name: toe
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 10m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      securityContext:
        runAsNonRoot: true
      serviceAccountName: teknoir-controller-manager
      priorityClassName: high-priority-toe
      terminationGracePeriodSeconds: 10
      volumes:
      - name: toe-volume
        hostPath:
          # directory location on host
          path: "/etc/teknoir"
EOL

mv ${FILE_TO_UPGRADE} ${FILE_TO_UPGRADE}.bak
mv ${FILE_TO_UPGRADE}.new ${FILE_TO_UPGRADE}

echo "Done"