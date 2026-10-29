(** Typed decoding of query results.

    A decoder turns the values of a record (or of a graph value) into an OCaml value. Field lookup
    is by name, using the field names the server reported for the result, so a decoder does not
    depend on column order.

    A decoder that reads record fields also reads the properties of a [Values.Node],
    [Values.Relationship] or [Values.Unbound_relationship] when it is applied to such a value. The
    same decoder therefore works for [RETURN p], [RETURN properties(p)] and a plain row of
    [RETURN p.name AS name, ...]:

    {v
    let person : person t =
      let open Decode in
      let+ name = field "name" string
      and+ age = field "age" int in
      { name; age }
    v}

    {!field} reports a missing key as an error; {!option} only accepts [Null], while {!field_opt}
    accepts both a missing key and [Null]. *)

(** The environment a decoder runs against: a record's named values, or a single value whose
    properties are read when the value is a [Map], [Node] or relationship. *)
type env = Row of (string * Values.t) list | Value of Values.t

type 'a t
(** A decoder producing an ['a] from an {!env}. *)

val decode_row : 'a t -> (string * Values.t) list -> ('a, Errors.t) result
(** Run a decoder against a record: a list of [(field_name, value)] pairs, as produced by
    [Neo4jResult.data] or by zipping [Neo4jResult.keys] with a record. *)

val decode_value : 'a t -> Values.t -> ('a, Errors.t) result
(** Run a decoder against a single value. A [Map] uses its entries; a [Node], [Relationship] or
    [Unbound_relationship] uses its properties. *)

val aliases : 'a t -> string list
(** The record field names the decoder {b requires} from its current environment. {!field}
    contributes only its own key (the nested decoder runs in a different environment); {!map}
    propagates and {!both} unions. {!field_opt} and {!field_or} tolerate a missing field and
    contribute nothing, so [Neo4jResult.check_keys] does not require them. *)

val row_of_values : keys:string list -> Values.t list -> ((string * Values.t) list, Errors.t) result
(** Zip a positional record with the result's field names. A length mismatch is a
    [Errors.Broken_record_error] instead of an exception. *)

val check_keys : keys:string list -> 'a t -> (unit, Errors.t) result
(** Check that the decoder can find every field it reads (its {!aliases}) in [keys]. Extra keys are
    allowed; a missing field or a duplicate key is an [Errors.Decode_error]. *)

(** {1 Primitive values} *)

val raw : Values.t t
(** The value as-is (including [Broken]). *)

val string : string t
val bool : bool t

val int : int t
(** A [Values.Int] that fits the OCaml [int] range; out-of-range values are an error. *)

val int64 : int64 t
val float : float t
val bytes : bytes t

val uuid : string t
(** A [Values.Uuid] in its canonical text form. *)

val date : Temporal.Date.t t
val time : Temporal.Time.t t
val datetime : Temporal.DateTime.t t
val duration : Temporal.Duration.t t
val point : Values.point t
val vector : Values.vector t
val node : Values.node t
val relationship : Values.relationship t
val unbound_relationship : Values.unbound_relationship t
val path : Values.path t

(** {1 Structure and composition} *)

val list : 'a t -> 'a list t
val array : 'a t -> 'a array t

val option : 'a t -> 'a option t
(** [Null] becomes [None]; any other value is decoded as [Some]. A missing field is still an error
    (use {!field_opt} for that). *)

val map : ('a -> 'b) -> 'a t -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val succeed : 'a -> 'a t

val fail : string -> 'a t
(** A decoder that always fails with the given message (for application-level validation). *)

val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t

(** {1 Record fields and properties} *)

val field : string -> 'a t -> 'a t
(** Read [key] and decode it. A missing key is an error listing the available fields. *)

val field_opt : string -> 'a t -> 'a option t
(** Like {!field}, but a missing key or [Null] is [None]. Such a field is optional, so it is not
    included in {!aliases} (and [Neo4jResult.check_keys] does not require it). *)

val field_or : string -> default:'a -> 'a t -> 'a t
(** Like {!field}, but a missing key or [Null] yields [default]. Such a field is optional, so it is
    not included in {!aliases}. *)
