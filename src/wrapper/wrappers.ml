open Base
module W = Bindings.C (Wasmtime_generated)

exception Trap of { message : string }

(* Taken from [Core_kernel.Gc]. *)
let zero = Sys.opaque_identity (Caml.int_of_string "0")

(* The compiler won't optimize int_of_string away so it won't
   perform constant folding below. *)
let rec keep_alive o = if zero <> 0 then keep_alive (Sys.opaque_identity o)

module Engine = struct
  type t = W.Engine.t

  let create () =
    let t = W.Engine.new_ () in
    if Ctypes.is_null t then failwith "Engine.new_ returned null";
    Caml.Gc.finalise W.Engine.delete t;
    t
end

module Store = struct
  type t = W.Store.t

  let create engine =
    let t = W.Store.new_ engine in
    if Ctypes.is_null t then failwith "Store.new_ returned null";
    Caml.Gc.finalise
      (fun t ->
        keep_alive engine;
        W.Store.delete t)
      t;
    t
end

module Byte_vec = struct
  type t = W.Byte_vec.t

  let with_finalise ~f =
    let t = Ctypes.allocate_n W.Byte_vec.struct_ ~count:1 in
    f t;
    Caml.Gc.finalise W.Byte_vec.delete t;
    t

  let create ~len =
    with_finalise ~f:(fun t ->
        W.Byte_vec.new_uninitialized t (Unsigned.Size_t.of_int len))

  let of_string str =
    with_finalise ~f:(fun t ->
        W.Byte_vec.new_ t (String.length str |> Unsigned.Size_t.of_int) str)

  let length t =
    let t = Ctypes.( !@ ) t in
    Ctypes.getf t W.Byte_vec.size |> Unsigned.Size_t.to_int

  let to_string t =
    let t = Ctypes.( !@ ) t in
    let length = Ctypes.getf t W.Byte_vec.size |> Unsigned.Size_t.to_int in
    let data = Ctypes.getf t W.Byte_vec.data in
    Ctypes.string_from_ptr data ~length
end

module Trap = struct
  type t = W.Trap.t

  let maybe_fail (t : t) =
    if not (Ctypes.is_null t)
    then (
      let message =
        Byte_vec.with_finalise ~f:(fun message -> W.Trap.message t message)
        |> Byte_vec.to_string
      in
      W.Trap.delete t;
      raise (Trap { message }))
end

module Module = struct
  type t = W.Module.t
end

module Instance = struct
  type t = W.Instance.t

  let exports t =
    let extern_vec = Ctypes.allocate_n W.Extern_vec.struct_ ~count:1 in
    Caml.Gc.finalise
      (fun extern_vec ->
        keep_alive t;
        W.Extern_vec.delete extern_vec)
      extern_vec;
    W.Instance.exports t extern_vec;
    let extern_vec = Ctypes.( !@ ) extern_vec in
    let size = Ctypes.getf extern_vec W.Extern_vec.size |> Unsigned.Size_t.to_int in
    let data = Ctypes.getf extern_vec W.Extern_vec.data in
    List.init size ~f:(fun i ->
        let extern = Ctypes.( +@ ) data i in
        if Ctypes.is_null extern then failwith "exports returned null";
        let extern = Ctypes.( !@ ) extern in
        Caml.Gc.finalise
          (fun extern ->
            keep_alive t;
            W.Extern.delete extern)
          extern;
        extern)
end

module Func = struct
  type t = W.Func.t
end

module Memory = struct
  type t = W.Memory.t

  let data_size t = W.Memory.data_size t |> Unsigned.Size_t.to_int
end

module Extern = struct
  type t = W.Extern.t

  let as_memory t =
    let mem = W.Extern.as_memory t in
    if Ctypes.is_null mem then failwith "as_memory returned null";
    (* The returned memory is owned by the extern so there is no need to
    delete it but it only stays alive until t does. *)
    Caml.Gc.finalise (fun _mem -> keep_alive t) mem;
    mem

  let as_func t =
    let func = W.Extern.as_func t in
    if Ctypes.is_null func then failwith "as_func returned null";
    (* The returned func is owned by the extern so there is no need to
    delete it but it only stays alive until t does. *)
    Caml.Gc.finalise (fun _func -> keep_alive t) func;
    func
end

module Val = struct
  type t =
    | Int32 of int
    | Int64 of int
    | Float32 of float
    | Float64 of float

  let int_exn = function
    | Int32 i | Int64 i -> i
    | Float32 f -> Printf.failwithf "expected an int, got f32 %f" f ()
    | Float64 f -> Printf.failwithf "expected an int, got f64 %f" f ()

  let float_exn = function
    | Int32 i -> Printf.failwithf "expected a float, got i32 %d" i ()
    | Int64 i -> Printf.failwithf "expected a float, got i64 %d" i ()
    | Float32 i | Float64 i -> i

  module Kind = struct
    type t =
      | Int32
      | Int64
      | Float32
      | Float64
      | Any_ref
      | Func_ref

    let to_c = function
      | Int32 -> 0
      | Int64 -> 1
      | Float32 -> 2
      | Float64 -> 3
      | Any_ref -> 128
      | Func_ref -> 129

    let of_c = function
      | 0 -> Int32
      | 1 -> Int64
      | 2 -> Float32
      | 3 -> Float64
      | 128 -> Any_ref
      | 129 -> Func_ref
      | otherwise -> Printf.failwithf "unexpected Val.kind value %d" otherwise ()
  end

  let kind = function
    | Int32 _ -> Kind.Int32
    | Int64 _ -> Kind.Int64
    | Float32 _ -> Kind.Float32
    | Float64 _ -> Kind.Float64
end

module Wasi_config = struct
  type t = W.Wasi_config.t

  let create () =
    let t = W.Wasi_config.new_ () in
    if Ctypes.is_null t then failwith "Wasi_config.new retuned null";
    Caml.Gc.finalise W.Wasi_config.delete t;
    t

  let inherit_argv = W.Wasi_config.inherit_argv
  let inherit_env = W.Wasi_config.inherit_env
  let inherit_stdin = W.Wasi_config.inherit_stdin
  let inherit_stdout = W.Wasi_config.inherit_stdout
  let inherit_stderr = W.Wasi_config.inherit_stderr
  let preopen_dir t d1 d2 = ignore (W.Wasi_config.preopen_dir t d1 d2 : bool)
end

module Wasi_instance = struct
  type t = W.Wasi_instance.t

  let create store name config =
    let trap = Ctypes.allocate W.Trap.t (Ctypes.from_voidp W.Trap.struct_ Ctypes.null) in
    let name =
      match name with
      | `wasi_unstable -> "wasi_unstable"
      | `wasi_snapshot_preview -> "wasi_snapshot_preview"
    in
    let t = W.Wasi_instance.new_ store name config trap in
    Ctypes.( !@ ) trap |> Trap.maybe_fail;
    if Ctypes.is_null t then failwith "Wasi_instance.new returned null";
    Caml.Gc.finalise
      (fun t ->
        keep_alive store;
        W.Wasi_instance.delete t)
      t;
    t
end

module Wasmtime = struct
  let fail_on_error error =
    if not (Ctypes.is_null error)
    then (
      let message =
        Byte_vec.with_finalise ~f:(fun message -> W.Error.message error message)
        |> Byte_vec.to_string
      in
      W.Error.delete error;
      failwith message)

  let wat_to_wasm ~wat =
    Byte_vec.with_finalise ~f:(fun wasm -> W.Wasmtime.wat2wasm wat wasm |> fail_on_error)

  let new_module engine ~wasm =
    let modl =
      Ctypes.allocate W.Module.t (Ctypes.from_voidp W.Module.struct_ Ctypes.null)
    in
    W.Wasmtime.new_module engine wasm modl |> fail_on_error;
    let modl = Ctypes.( !@ ) modl in
    if Ctypes.is_null modl then failwith "new_module returned null";
    Caml.Gc.finalise
      (fun modl ->
        keep_alive engine;
        W.Module.delete modl)
      modl;
    modl

  let new_instance store modl =
    let instance =
      Ctypes.allocate W.Instance.t (Ctypes.from_voidp W.Instance.struct_ Ctypes.null)
    in
    let trap = Ctypes.allocate W.Trap.t (Ctypes.from_voidp W.Trap.struct_ Ctypes.null) in
    let null_ext = Ctypes.from_voidp W.Extern.t Ctypes.null in
    W.Wasmtime.new_instance store modl null_ext Unsigned.Size_t.zero instance trap
    |> fail_on_error;
    Ctypes.( !@ ) trap |> Trap.maybe_fail;
    let instance = Ctypes.( !@ ) instance in
    if Ctypes.is_null instance then failwith "new_instance returned null";
    Caml.Gc.finalise
      (fun instance ->
        keep_alive (store, modl);
        W.Instance.delete instance)
      instance;
    instance

  let func_call func args ~n_outputs =
    let trap = Ctypes.allocate W.Trap.t (Ctypes.from_voidp W.Trap.struct_ Ctypes.null) in
    let n_args = List.length args in
    let args_ = Ctypes.allocate_n W.Val.struct_ ~count:n_args in
    List.iteri args ~f:(fun idx val_ ->
        let arg_i = Ctypes.( +@ ) args_ idx |> Ctypes.( !@ ) in
        let kind = Val.kind val_ |> Val.Kind.to_c |> Unsigned.UInt8.of_int in
        Ctypes.setf arg_i W.Val.kind kind;
        let op = Ctypes.getf arg_i W.Val.op in
        match val_ with
        | Int32 i -> Ctypes.setf op W.Val.i32 (Int32.of_int_exn i)
        | Int64 i -> Ctypes.setf op W.Val.i64 (Int64.of_int_exn i)
        | Float32 f -> Ctypes.setf op W.Val.f32 f
        | Float64 f -> Ctypes.setf op W.Val.f64 f);
    let outputs = Ctypes.allocate_n W.Val.struct_ ~count:n_outputs in
    W.Wasmtime.func_call
      func
      args_
      (Unsigned.Size_t.of_int n_args)
      outputs
      (Unsigned.Size_t.of_int n_outputs)
      trap
    |> fail_on_error;
    Ctypes.( !@ ) trap |> Trap.maybe_fail;
    List.init n_outputs ~f:(fun idx ->
        let out_i = Ctypes.( +@ ) outputs idx |> Ctypes.( !@ ) in
        let kind =
          Ctypes.getf out_i W.Val.kind |> Unsigned.UInt8.to_int |> Val.Kind.of_c
        in
        let op = Ctypes.getf out_i W.Val.op in
        match kind with
        | Int32 -> Val.Int32 (Ctypes.getf op W.Val.i32 |> Int32.to_int_exn)
        | Int64 -> Val.Int64 (Ctypes.getf op W.Val.i64 |> Int64.to_int_exn)
        | Float32 -> Val.Float32 (Ctypes.getf op W.Val.f32)
        | Float64 -> Val.Float64 (Ctypes.getf op W.Val.f64)
        | Any_ref -> failwith "any_ref returned results are not supported"
        | Func_ref -> failwith "func_ref returned results are not supported")

  let func_call0 func args =
    match func_call func args ~n_outputs:0 with
    | [] -> ()
    | l -> Printf.failwithf "expected no output, got %d" (List.length l) ()

  let func_call1 func args =
    match func_call func args ~n_outputs:1 with
    | [ res ] -> res
    | l -> Printf.failwithf "expected a single output, got %d" (List.length l) ()

  let func_call2 func args =
    match func_call func args ~n_outputs:2 with
    | [ res1; res2 ] -> res1, res2
    | l -> Printf.failwithf "expected two outputs, got %d" (List.length l) ()

  module Linker = struct
    type t = W.Wasmtime.Linker.t

    let create store =
      let t = W.Wasmtime.Linker.new_ store in
      Caml.Gc.finalise
        (fun t ->
          keep_alive store;
          W.Wasmtime.Linker.delete t)
        t;
      t

    let define_wasi t wasi_instance =
      W.Wasmtime.Linker.define_wasi t wasi_instance |> fail_on_error

    let module_ t ~name modl = W.Wasmtime.Linker.module_ t name modl |> fail_on_error

    let get_default t ~name =
      let func =
        Ctypes.allocate W.Func.t (Ctypes.from_voidp W.Func.struct_ Ctypes.null)
      in
      W.Wasmtime.Linker.get_default t name func |> fail_on_error;
      let func = Ctypes.( !@ ) func in
      if Ctypes.is_null func then failwith "Linker.get_default returned null";
      Caml.Gc.finalise
        (fun func ->
          keep_alive t;
          W.Func.delete func)
        func;
      func
  end
end