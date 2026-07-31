type t = { debug : string -> unit; info : string -> unit }

let make ~debug ~info = { debug; info }
let silent = { debug = (fun _ -> ()); info = (fun _ -> ()) }
let debug reporter format = Printf.ksprintf reporter.debug format
let info reporter format = Printf.ksprintf reporter.info format
