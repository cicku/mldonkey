(* Copyright 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

open Unix

let verbose = false
  
(**************** TYPES *******************)  
  
type 'a file = {
    file_name : string;
    file_entry_size : int;
    file_fd : Unix.file_descr;
    mutable file_len : int;
    mutable file_all_pos : int array;
    mutable file_cache : 'a Weak.t;
    mutable file_next_pos : int;
    file_chunk : string;
  }

  
type 'a t = {
    mutable store_files  : (int * 'a file) list;
    mutable store_next_doc : int;
    mutable store_all_doc : int array;
  }

  
let attrib = 1 lsl 30

(**************** UNIX I/O FUNCTIONS *******************)  
  
external ftruncate32 : Unix.file_descr -> int32 -> unit = "ml_truncate32"
external seek32 : Unix.file_descr -> int32 -> Unix.seek_command -> int32 =
  "ml_lseek32"

let rec iter_write fd s pos len =
  let nwrite = Unix.write fd s pos len in
  if nwrite < len then
    iter_write fd s (pos+nwrite) (len-nwrite)
    
let really_write fd pos s =
  let len = String.length s in
  if verbose then begin
      Printf.printf "write %d %d" pos len; print_newline ();
    end;
  ignore (seek32 fd  (Int32.of_int pos) Unix.SEEK_SET);
  iter_write fd s 0 len

let rec iter_read fd s pos len =
  let nread = Unix.read fd s pos len in
  if nread < len then
    iter_read fd s (pos + nread) (len - nread)
  
let really_read fd pos s len =
  if verbose then begin
      Printf.printf "read %d %d" pos len; print_newline ();
    end;
  ignore (seek32 fd  (Int32.of_int pos) Unix.SEEK_SET);
  iter_read fd s 0 len

(********************* FILE FUNCTIONS *****************)
  
let gen_file n =
  Printf.sprintf "store_%d" n
    
let create_file file file_entry_size = 
  let name = gen_file file_entry_size in
  {
    file_name = name;
    file_entry_size = file_entry_size;
    file_fd = Unix.openfile name [O_RDWR; O_CREAT; O_TRUNC] 0o666;
    file_len = 0;
    file_all_pos = [||];
    file_cache = Weak.create 1;
    file_next_pos = 0;
    file_chunk = String.create file_entry_size;
  }
    
let file_store file str = 
  let pos = file.file_next_pos in
  let len_all_pos = Array.length file.file_all_pos in
  if pos >= len_all_pos then begin
      let new_size = (len_all_pos + 10) * 2 in
      ftruncate32 file.file_fd (Int32.of_int (new_size * file.file_entry_size));
      let new_tab = Array.create new_size 0 in
      let new_weak = Weak.create new_size in
      (try Array.blit file.file_all_pos 0 new_tab 0 pos
        with e ->
            Printf.printf "exc pos %d" pos; print_newline ();
            raise e);
      Weak.blit file.file_cache 0 new_weak 0 pos;
      for i = pos to new_size - 1 do new_tab.(i) <- i+1; done;
      file.file_all_pos <- new_tab;
      file.file_cache <- new_weak;
    end;
  file.file_next_pos <- file.file_all_pos.(pos);
  really_write file.file_fd (pos * file.file_entry_size) str;
  pos
  
let file_retrieve file pos =
  really_read file.file_fd (pos * file.file_entry_size) file.file_chunk 
    file.file_entry_size;
  file.file_chunk

let file_close file =
  Unix.close file.file_fd;
  Sys.remove file.file_name
  
let file_remove file pos =
  file.file_all_pos.(pos) <- file.file_next_pos;
  file.file_next_pos <- pos

(********************** STORE FUNCTIONS *****************)
  
let max_cache_size = 2000
  
let create  () =
  {
    store_files = [];
    store_all_doc = [||];
    store_next_doc = 0;
  }

let rec chunk_size n =
  if n < 128 then 0 else 1 + chunk_size (n/2)

let combine pos chunk_size attr = 
  let v =   pos lsl 6 + chunk_size in
  if attr then v lor attrib else v

let uncombine comb =
  let attr = comb land attrib <> 0 in
  let pos = (comb land (lnot attrib)) lsr 6 in
  let chunk_size = comb land 31 in
  pos, chunk_size, attr
    
let save t doc v attr =  
  let str = Marshal.to_string v [] in
  let len = String.length str in
  let chunk_size = chunk_size len in
  let file = try
      List.assoc chunk_size t.store_files
    with Not_found ->
        let file = create_file chunk_size (128 lsl chunk_size) in
        t.store_files <- t.store_files @ [chunk_size ,file];
        file
  in
  let pos = file_store file str in
  if verbose then begin
      Printf.printf "REALLY WRITE TO %d POS %d LEN %d"
        chunk_size pos len;
      print_newline ();
    end;
  Weak.set file.file_cache pos (Some v);
  let comb = combine pos chunk_size attr in
  t.store_all_doc.(doc) <- comb
  
let add t v =  
  let doc = t.store_next_doc in
  let len_all_doc = Array.length t.store_all_doc in
  if doc >= len_all_doc then begin
      let new_size = (len_all_doc + 10) * 2 in
      let new_tab = Array.create new_size 0 in
      (try Array.blit t.store_all_doc 0 new_tab 0 doc
        with e -> Printf.printf "Error in blit %d/%d" doc len_all_doc; print_newline ();
            raise e)
          ;
      for i = doc to new_size - 1 do new_tab.(i) <- i+1; done;
      t.store_all_doc <- new_tab
    end;
  t.store_next_doc <- t.store_all_doc.(doc);
  save t doc v false;
  doc
  
let get t doc = 
  let combine = t.store_all_doc.(doc) in
  let pos, chunk_size, attrib = uncombine combine in
  let file = List.assoc chunk_size t.store_files in
  let v =  try Weak.get file.file_cache pos 
    with e ->
        Printf.printf "Exception %s for doc at pos %d (doc %d, combine %d)" (Printexc.to_string e)
        pos doc combine; print_newline ();
        raise e
      in
  match v with
    None ->
      let len = file.file_entry_size in
      if verbose then begin
          Printf.printf "REALLY READ FROM %d POS %d LEN %d"
            chunk_size pos len;
          print_newline (); 
        end;
      let str = file_retrieve file pos in
      begin
        try
          Marshal.from_string str 0
        with e ->
            Printf.printf "Marshal.from_string error"; 
            print_newline (); raise e
      end
  | Some v -> 
      if verbose then begin
          Printf.printf "Reply found in cache"; print_newline (); 
        end;
      v

      
let remove t doc = 
  let combine = t.store_all_doc.(doc) in
  let pos, chunk_size, attr = uncombine combine in
  let file = List.assoc chunk_size t.store_files in
  file_remove file pos;
  Weak.set file.file_cache pos None
  
let close t = 
  let files = t.store_files in
  t.store_files <- [];
  List.iter (fun (_, file) -> file_close file) files
  
let set_attrib t doc bool =
  if bool then
    t.store_all_doc.(doc) <- t.store_all_doc.(doc) lor attrib
  else
  let bin = t.store_all_doc.(doc) in
  t.store_all_doc.(doc) <-  bin land (lnot attrib)
    
let get_attrib t doc =
  t.store_all_doc.(doc) land attrib <> 0
  
let update t doc v =
  let combine = t.store_all_doc.(doc) in
  let _, _, attr = uncombine combine in
  remove t doc;
  save t doc v attr 
  
let remove t doc =
  remove t doc;
  t.store_all_doc.(doc) <- t.store_next_doc;
  t.store_next_doc <- doc
  