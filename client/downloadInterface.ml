(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
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

open Options
open Mftp
open Mftp_comm
open DownloadServers
open BasicSocket
open DownloadComplexOptions
open TcpClientSocket
open DownloadOneFile
open DownloadFiles
open DownloadTypes
open DownloadOptions
open DownloadGlobals
open DownloadClient
open Gui_types
  
module P = Gui_proto
  
  
let gui_send gui t = value_send gui.gui_sock (t : Gui_proto.to_gui)

let restart_gui_server = ref (fun _ -> ())
  
let send_result gui num r =
(*  Printf.printf "send result"; print_newline (); *)
  if List.mem    num gui.gui_search_nums then begin
    let module P = Gui_proto in
    gui_send gui (P.Search_result {
      P.result_num = num;
      P.result_res = r;
      });
(*    Printf.printf "result sent"; print_newline ();  *)
    end
  
let send_waiting gui num r =
  if List.mem    num gui.gui_search_nums then 
    let module P = Gui_proto in
    gui_send gui (P.Search_waiting (num,r))


let file_info file = 
  {
    P.file_num = file.file_num;
    P.file_name = file.file_filenames;
    P.file_md4 = file.file_md4;
    P.file_size = file.file_size;
    P.file_downloaded = file.file_downloaded;
    P.file_nlocations = 0;
    P.file_nclients = 0;
    P.file_state = file.file_state;
    P.file_more_info = None;
    P.file_download_rate = file.file_last_rate;
    P.file_chunks = file.file_all_chunks;
    P.file_availability = String2.init file.file_nchunks (fun i ->
        if file.file_available_chunks.(i) > 1 then '2' else
        if file.file_available_chunks.(i) > 0 then '1' else
          '0');
    P.file_format = file.file_format;
  }

and client_info c = 
  {
    P.client_kind = c.client_kind;
(*
    P.client_md4 = c.client_md4;
    P.client_chunks = c.client_all_chunks;
    P.client_files = List.map (fun (file, availability) ->
        file.file_md4, String2.init file.file_nchunks (fun i ->
if availability.(i) then '1' else '0')) c.client_files;
*)
    P.client_state = c.client_state;
    P.client_is_friend = c.client_is_friend;
    P.client_tags = c.client_tags;
    P.client_name = c.client_name;
    P.client_files = None;
    P.client_num = c.client_num;
    P.client_rating = c.client_rating;
  }

  (*
let more_file_info file = 
  {
    P.file_known_locations = 
    List2.tail_map client_info file.file_known_locations; 
    P.file_indirect_locations = 
    List2.tail_map client_info file.file_indirect_locations;
  }
    *)
  
let server_info s =
  {
    P.server_num = s.server_num;
    P.server_ip = s.server_ip;
    P.server_port = s.server_port;
    P.server_score = s.server_score;
    P.server_tags = s.server_tags;
    P.server_nusers = s.server_nusers;
    P.server_nfiles = s.server_nfiles;
    P.server_state = s.server_state;
    P.server_name = s.server_name;
    P.server_description = s.server_description;
    P.server_users = None;
  } 

let user_info s u = {
    P.user_md4 = u.user_md4;
    P.user_ip = u.user_ip;
    P.user_port = u.user_port;
    P.user_tags = u.user_tags;
    P.user_server = { P.key_ip = s.server_ip; P.key_port = s.server_port };
    P.user_name = u.user_name;
  }
    
let server_users s = List2.tail_map (user_info s) s.server_users
  
let send_file_info gui file =
  let module P = Gui_proto in  
(*  Printf.printf "SEND INFO"; print_newline (); *)
  gui_send gui (P.File_info (file_info file))

let send_full_file_info gui file =
  let module P = Gui_proto in  
  let file_info = file_info file in
(*  file_info.P.file_more_info <- Some (more_file_info file); *)
(*  Printf.printf "SEND INFO"; print_newline (); *)
  gui_send gui (P.File_info file_info)
  
  
  
  
let send_server_info gui s =
  gui_send gui (P.Server_info (server_info s))

  (*
let send_full_server_info gui s =
  let module P = Gui_proto in  
  let server_info = server_info s in
  server_info.P.server_more_info <- Some (more_server_info s);
  gui_send gui (P.Server_info server_info)
  *)

let send_client_info gui c =
  let module P = Gui_proto in  
  gui_send gui (P.Client_info (client_info c))

  (*
let send_full_client_info gui c =
  let module P = Gui_proto in  
  let client_info = client_info c in
  client_info.P.client_more_info <- Some (more_client_info c);
  gui_send gui (P.Client_info client_info)
  *)

let new_friend c =  
  match c.client_is_friend with
    Friend -> ()
  | _ ->
      c.client_is_friend <- Friend;
      begin
        match c.client_kind with
          Known_location _ -> 
            known_friends =:= c :: !!known_friends;
        |  _ -> ()
      end;
      c.client_changed <- ClientFriendChange;
      !client_change_hook c;
      
      match c.client_sock, c.client_state with
      | None, NotConnected ->
          connection_must_try c.client_connection_control;
          connect_client !!client_ip [] c
      | None, _ -> ()
      | Some sock, (
          Connected_initiating 
        | Connected_busy
        | Connected_queued
        | Connected_idle)
        ->
          client_send sock (
            let module M = Mftp_client in
            let module C = M.ViewFiles in
            M.ViewFilesReq C.t);          
      | _ -> ()
          
let view_users_handler s sock t =
  let module M = Mftp_server in
  let module Q = M.QueryUsersReply in
  s.server_users <- [];
  List.iter (fun t ->
      let u = {
          user_md4 = t.Q.md4;
          user_ip = t.Q.ip;
          user_port = t.Q.port;
          user_tags = t.Q.tags;
          user_name = "";
        } in
      List.iter (fun tag ->
          match tag with
            { tag_name = "name"; tag_value = String s } -> 
              u.user_name <- s
          | _ -> ()
      ) u.user_tags;

      s.server_users <- u :: s.server_users
  ) t;
  s.server_changed <- ServerUsersChange;
  !server_change_hook s

let add_user_friend s u = 
  if Ip.valid u.user_ip then
    let c = new_client (Known_location (u.user_ip, u.user_port)) in
    c.client_tags <- u.user_tags;
    c.client_md4 <- u.user_md4;
    c.client_name <- u.user_name;
    new_friend c
  else
  let key = u.user_name, u.user_md4 in
  begin
    try
      ignore (Hashtbl.find indirect_friends key);
    with _ -> 
        Hashtbl.add indirect_friends key ()
  end;
  match s.server_sock, s.server_state with 
    Some sock, (Connected_idle|Connected_busy) ->
      query_id s sock u.user_ip;
  | _ -> ()


let file_locations file = 
  
  let ilocs = ref [] in
  let locs = ref [] in
  List.iter (fun c ->
        ilocs := c.client_num :: !ilocs
  ) file.file_indirect_locations;
  List.iter (fun c ->
        locs := c.client_num :: !locs
  ) file.file_known_locations;
  
  let m = P.File_locations (file.file_num,
      Array.of_list !ilocs,
      Array.of_list !locs) in
  m
  
let find_user_handler s sock t =
  let module M = Mftp_server in
  let module Q = M.QueryUsersReply in
  List.iter (fun cl ->
(* We MUST found a way to keep indirect friends even after a deconnexion.
Add a connection num to server. Use Indirect_location (server_num, conn_num)
and remove clients whose server is deconnected. *)
      
      let client_name = ref "" in
        List.iter (fun tag ->
            match tag with
              { tag_name = "name"; tag_value = String s } -> 
                client_name := s
            | _ -> ()
      ) cl.Q.tags;

      add_user_friend s {
        user_md4 = cl.Q.md4;
        user_name = !client_name;
        user_ip = cl.Q.ip;
        user_port = cl.Q.port;
        user_tags = cl.Q.tags;
      }
  ) t
  
  
let server_of_key t =
  try
    find_server t.P.key_ip t.P.key_port  
  with Not_found ->
      Printf.printf "No server %s:%d" (Ip.to_string t.P.key_ip)
      t.P.key_port;
      print_newline ();
      raise Not_found
  
let gui_reader (gui: gui_record) t sock =

  if Obj.is_int (Obj.repr t) then
    Printf.printf "from gui: int %d" (Obj.magic t)
  else
    Printf.printf "from gui: %d" (Obj.tag (Obj.repr t)); 
print_newline ();
  
  try
    let module P = Gui_proto in
    match t with
    | P.Command cmd ->
        let buf = Buffer.create 1000 in
        Buffer.add_string buf "\n----------------------------------\n";
        Printf.bprintf buf "Eval command: %s\n\n" cmd;
        let options = { conn_output = TEXT; conn_sortvd = BySize } in
        DownloadInteractive.eval (ref true) buf cmd 
        options;
        Buffer.add_string buf "\n\n";
        gui_send gui (P.Console (Buffer.contents buf))
    
    | P.SetOption (name, value) ->
        Options.set_simple_option downloads_ini name value
    
    | P.ForgetSearch num ->
        begin
          try
            DownloadInteractive.forget_search (List.assoc num gui.gui_searches)
          with _ -> ()
        end


    | P.ExtendedSearch ->
        if !last_xs >= 0 then begin
            try
              let ss = DownloadFiles.find_search !last_xs in
              make_xs ss;
            with _ -> ()
          end
    
    | P.Password (v,s) ->
        if v <> Gui_types.version then begin
            Printf.printf "Bad GUI version"; print_newline ();
            TcpClientSocket.close sock "bad version";
          end;
        if s = !!password then begin
            BasicSocket.must_write (TcpClientSocket.sock sock) true;
            let connecting = ref true in
            
            gui_send gui (
              P.Options_info (simple_options downloads_ini));
            
            set_handler sock WRITE_DONE (fun _ ->
                if !connecting then
                  try
                    while TcpClientSocket.can_write sock do
                      match gui.gui_files with
                        file :: files ->
                          gui.gui_files <- files;
                          send_file_info gui file
                      | [] -> 
                          match gui.gui_friends with
                            c :: friends ->
                              gui.gui_friends <- friends;
                              send_client_info gui c;
                              begin
                                match c.client_all_files with
                                  None -> ()
                                | Some files ->
                                    gui_send gui (P.Client_files (
                                        c.client_num, Some (
                                          List2.tail_map (
                                            Store.get DownloadIndexer.store) files)))
                              end
                          | [] ->
                              match gui.gui_servers with
                                s :: servers ->
                                  gui.gui_servers <- servers;
                                  send_server_info gui s
                              | [] -> raise Not_found
                    done;
                  with _ -> 
                      List.iter (fun (name,s) ->
                          gui_send gui (P.Dialog (name, s))
                      ) (List.rev !dialog_history);
                      
                      gui_send gui (P.GuiConnected);
                      connecting := false
            );
          
          end else
          TcpClientSocket.close gui.gui_sock "bad password"
    
    | P.KillServer -> 
        exit_properly ()
    
    | P.Search_query (local,s) ->
(*        Printf.printf "from gui: search"; print_newline (); *)
        incr search_counter;
        gui.gui_search_nums <- s.P.search_num ::  gui.gui_search_nums;
        gui.gui_searches <- 
          (s.P.search_num, !search_counter) :: gui.gui_searches;
        let rec search = {
            search_max_hits = s.P.search_max_hits;
            search_query = s.P.search_query;
            search_files = Hashtbl.create 127;
            search_num = !search_counter;
            search_nresults = 0;
            search_waiting = List.length !connected_server_list;
            search_string = DownloadSearch.search_string s.P.search_query;
            search_handler = (fun ev -> 
                match ev with
                  Result r -> send_result gui s.P.search_num r
                | Waiting n -> send_waiting gui s.P.search_num n
            );
            search_xs_servers = !!known_servers;
          } 
        in            
        searches := search :: !searches;
        if local then
          DownloadIndexer.find search
        else
        let query = search.search_query in
        DownloadSearch.send_search search  query
    
    | P.Download_query (filenames, size, md4, location) ->
(*        Printf.printf "from gui: download"; print_newline (); *)
        DownloadInteractive.query_download filenames size md4 location None None;
        
        send_full_file_info gui (find_file md4)
    
    | P.ConnectMore_query ->
        force_check_server_connections true
    
    | P.AddServer_query t ->
        let s = add_server t.P.key_ip t.P.key_port in
        !server_change_hook s
    
    | P.RemoveServer_query t ->
        DownloadComplexOptions.remove_server t.P.key_ip t.P.key_port 
    
    | P.SaveOptions_query list ->
        
        List.iter (fun (name, value) ->
            Printf.printf "%s:%s" name value; print_newline ();
            set_simple_option downloads_ini name value) list;
        force_save_options ()
    
    | P.RemoveDownload_query md4 ->
(*        Printf.printf "REMOVE DOWNLOAD"; print_newline (); *)
        remove_file md4
    
        
        
    | P.ServerUsers_query t -> 
        begin
          try
            let s = Hashtbl2.find servers_by_key (t.P.key_ip, t.P.key_port)
            in
            match s.server_sock with
              None -> ()
            | Some sock ->
(*                server_send sock *)
                ()
          with _ -> ()
        end
    
    
    | P.SaveFile (md4, name) ->
        DownloadInteractive.save_file md4 name
    
    | P.Preview md4 ->
        begin
          let file = find_file md4 in
          let cmd = Printf.sprintf "%s \"%s\" \"%s\"" !!previewer
              file.file_hardname (first_name file) in
          ignore (Sys.command cmd)
        end
          

        
    | P.AddFriend num ->
        let c = find_client num in
        new_friend c
        
    | P.GetClient_files num ->
        let c = find_client num in
        begin
          match c.client_all_files with
            None -> ()
          | Some files ->
              gui_send gui (P.Client_files (c.client_num, 
                  Some (
                    List2.tail_map (Store.get DownloadIndexer.store) files)))
        end
    | P.GetClient_info num ->
        begin
          try
            let c = find_client num in
            if c.client_md4 <> Md4.null || c.client_is_friend = Friend then
              gui_send gui (P.Client_info (client_info c))
          with Not_found -> ()
        end
        
    | P.GetServer_users key ->
        let s = server_of_key key in
        gui_send gui (P.Server_users (key, server_users s))

    | P.GetServer_info key ->
        let  s = server_of_key key in
        gui_send gui (P.Server_info (server_info s))
          
    
    | P.GetFile_locations md4 ->
        begin
          try
            let file = find_file md4 in
            gui_send gui (file_locations file)

          with _ -> ()
        end
        
    | P.GetFile_info md4 ->
        begin
          try
            gui_send gui (P.File_info (file_info (find_file md4)))
          with _ -> ()
        end
        
    | P.ConnectFriend num ->
        let c = find_client num in
        connection_must_try c.client_connection_control;
        connect_client !!client_ip [] c

    | P.AddNewFriend (ip, port) ->
        
        let c = new_client (Known_location (ip,port)) in
        new_friend c
        
    | P.ConnectServer key -> 
        connect_server (server_of_key key)
    
    | P.DisconnectServer key -> 
        begin
          let s = server_of_key key in
          match s.server_sock with
            None -> ()
          | Some sock ->
              shutdown sock "user disconnect"
        end
    
    | P.ConnectAll md4 -> 
        begin
          try
            let file = find_file md4 in
            if file.file_state = FileDownloading then 
              DownloadInteractive.reconnect_all file          
          with _ -> ()
        end
    
    | P.QueryFormat md4 ->
        begin
          try
            let file = find_file md4 in
            let format = DownloadMultimedia.get_info file.file_hardname in
            file.file_format <- format;
            info_change_file file
          with _ -> ()
        end
    
    | P.ModifyMp3Tags (md4, tag) ->
        begin
          try 
            let file = find_file md4 in
(*            Printf.printf "Setting mp3 tags"; print_newline () ; *)
            let filename = file.file_hardname in
(*            Printf.printf "EDIT"; print_newline (); *)
            Mp3tag.write tag filename;
(*            Printf.printf "Mp3 tags ok." *)
          with 
            _ -> ()
        end
    
    | P.SwitchDownload md4 ->
        let file = find_file md4 in
        begin
          match file.file_state with
            FilePaused ->
              file.file_state <- FileDownloading;
              DownloadInteractive.reconnect_all file
          
          | _ -> 
              file.file_state <- FilePaused;
        end;
        file.file_changed <- FileInfoChange;
        !file_change_hook file
    
    | P.ViewUsers key -> 
        begin
          let s = server_of_key key in
          match s.server_sock, s.server_state with
            Some sock, (Connected_idle | Connected_busy) ->
              server_send sock (Mftp_server.QueryUsersReq "");
              Fifo.put s.server_users_queries view_users_handler              
          | _ -> ()
        end
    
    | P.FindFriend user -> 
        begin
          List.iter (fun s ->
              match s.server_sock, s.server_state with
                Some sock, (Connected_idle | Connected_busy) ->
                  server_send sock (Mftp_server.QueryUsersReq user);
                  Fifo.put s.server_users_queries find_user_handler
              | _ -> ()
          ) !connected_server_list;
        end
    
    | P.RemoveFriend num -> 
        begin
          let c = find_client num  in
          c.client_is_friend <- FriendRemoved;
          c.client_changed <- ClientFriendChange;
          !client_change_hook c;
          c.client_is_friend <- NotAFriend;
          known_friends =:= List2.removeq c !!known_friends;
          try
            Hashtbl.remove indirect_friends (c.client_name, c.client_md4)
          with _ -> ()
        end
    
    | P.SayFriends (s, friend_list) ->
        List.iter (fun num ->
            try
(*              Printf.printf "say to %d" num; print_newline (); *)
              let c = find_client num in
              match c.client_sock with
                None -> ()
              | Some sock ->
                  client_send sock (Mftp_client.SayReq s)
            with _ -> ()) friend_list;
        !say_hook None s
        
        
    | P.CleanOldServers -> 
        DownloadServers.remove_old_servers ()
    
    | P.AddUserFriend u ->
        let key = u.P.user_server in
        let s = find_server key.P.key_ip key.P.key_port in
        add_user_friend s {
          user_md4 = u.P.user_md4;
          user_ip = u.P.user_ip;
          user_port = u.P.user_port;
          user_tags = u.P.user_tags;
          user_name = u.P.user_name;
        }
    
    | P.VerifyAllChunks md4 ->
        begin
          try
            let file = find_file md4 in
            DownloadOneFile.verify_chunks file
          with _ -> ()
        end
        
    | P.SendMoreInfo (md4_list, num_list) ->
        List.iter (fun md4 ->
            try 
              let file = find_file md4 in
              if file.file_known_locations != [] ||
                file.file_indirect_locations != [] then
                send_full_file_info gui file with _ -> ()) md4_list;
        List.iter (fun num ->
            let c = find_client num in
            if c.client_all_files != None then
              send_client_info gui c) num_list;        
        List.iter (fun (name,s) ->
            gui_send gui (P.Dialog (name, s))
        ) (List.rev !dialog_history);
        
        
  with e ->
      Printf.printf "from_gui: exception %s" (Printexc.to_string e);
      print_newline ()
  
let gui_closed gui sock  msg =
  guis := List2.removeq gui !guis;
  ()
  
let gui_handler t event = 
(*  Printf.printf "CONNECTION FROM REMOTE USER"; print_newline (); *)
  match event with
    TcpServerSocket.CONNECTION (s, Unix.ADDR_INET (from_ip, from_port)) ->
      let from_ip = Ip.of_inet_addr from_ip in
      if Ip.matches from_ip !!allowed_ips then 
        
        let module P = Gui_proto in
        let sock = TcpClientSocket.create_simple s in
        let gui = {
            gui_searches = [];
            gui_sock = sock;
            gui_search_nums = [];
                        
            gui_files = !!files @ !!done_files;
            gui_friends = !!known_friends;
            gui_servers = !!known_servers;

          } in
        TcpClientSocket.set_max_write_buffer sock !!interface_buffer;
        TcpClientSocket.set_reader sock (Mftp.value_handler 
            (gui_reader gui));
        TcpClientSocket.set_closer sock (gui_closed gui);
        TcpClientSocket.set_handler sock TcpClientSocket.BUFFER_OVERFLOW
          (fun _ -> Printf.printf "BUFFER OVERFLOW"; print_newline () );
        guis := gui :: !guis;
        gui_send gui (P.Connected Gui_types.version);
      else 
        Unix.close s
  | _ -> ()
      
let key s = { P.key_ip = s.server_ip; P.key_port = s.server_port }
      
let gui_server_change_hook s gui = 
  match s.server_changed with
    NoServerChange -> ()
  | ServerStateChange ->
      gui_send gui (P.Server_state (key s, s.server_state))
  | ServerInfoChange -> send_server_info gui s
  | ServerUsersChange ->
      gui_send gui (P.Server_users (key s, server_users s ))
  | ServerBusyChange ->
      gui_send gui (P.Server_busy (key s, s.server_nusers, s.server_nfiles))
        
let gui_client_change_hook c gui = 
  match c.client_changed with
    NoClientChange ->  ()
  | ClientStateChange -> 
      gui_send gui (P.Client_state (c.client_num, c.client_state))
  | ClientFilesChange ->
      begin
        match c.client_all_files with
          None -> ()
        | Some files ->
            gui_send gui (P.Client_files (
                c.client_num, Some (
                  List2.tail_map (
                    Store.get DownloadIndexer.store) files)))            
      end
  | ClientFriendChange ->
      gui_send gui (P.Client_friend (c.client_num, c.client_is_friend))
  | ClientInfoChange -> send_client_info gui c
  
let gui_friend_change_hook friend gui = 
  ()
  
let gui_file_change_hook file gui = 
  send_file_info gui file

let gui_say_hook gui name s =
  gui_send gui (P.Dialog (name, s))
      
let update_gui_info timer =
  reactivate_timer timer;
  List.iter (fun file ->
      let time = last_time () -. file.file_last_time in
      let diff =  Int32.sub file.file_downloaded file.file_last_downloaded in
      file.file_last_time <- last_time ();
      let rate = if time > 0.0 && diff > Int32.zero then begin
            (Int32.to_float diff) /. time;
          end else 0.0
      in
      if rate <> file.file_last_rate || 
        file.file_downloaded <> file.file_last_downloaded then begin
          file.file_last_rate <- rate;
          file.file_last_downloaded <- file.file_downloaded;
          let m = P.File_downloaded (file.file_num, file.file_downloaded,
              rate) in
          List.iter (fun gui ->
              gui_send gui m) !guis;
        end;
      
      begin
        match file.file_changed with
          NoFileChange -> ()
        | FileAvailabilityChange ->
            let m = P.File_availability (file.file_num,
                file.file_all_chunks,
                String2.init file.file_nchunks (fun i ->
                    if file.file_available_chunks.(i) > 1 then '2' else
                    if file.file_available_chunks.(i) > 0 then '1' else
                      '0'))
            in
          List.iter (fun gui ->
              gui_send gui m) !guis;
            
        | FileInfoChange ->
            List.iter (fun gui -> send_file_info gui file) !guis;
      end;
      file.file_changed <- NoFileChange;
      
      if file.file_new_locations then begin
          file.file_new_locations <- false;
          
          let m = file_locations file in
          List.iter (fun gui -> gui_send gui m) !guis;
          
        end
  ) !!files;
  let msg = P.LocalInfo {
      P.upload_counter = !upload_counter;
      P.shared_files = !nshared_files;
    } in
  List.iter (fun gui -> gui_send gui msg) !guis

let install_hooks () =
  let old_hook = !friend_change_hook in
  friend_change_hook := (fun friend ->
      List.iter (gui_friend_change_hook friend) !guis;
      old_hook friend
  );
  let old_hook = !server_change_hook in
  server_change_hook := (fun server ->
      List.iter (gui_server_change_hook server) !guis;
      old_hook server
  );
  let old_hook = !client_change_hook in
  client_change_hook := (fun client ->
      List.iter (gui_client_change_hook client) !guis;
      old_hook client
  );
  let old_hook = !file_change_hook in
  file_change_hook := (fun file ->
      List.iter (gui_file_change_hook file) !guis;
      old_hook file
  );
  List.iter (fun (name,_) ->
      set_option_hook downloads_ini name (fun _ ->
          List.iter (fun gui ->
              gui_send gui (P.Options_info [name, 
                  get_simple_option downloads_ini name])
          ) !guis
      )
  ) (simple_options downloads_ini);
  let old_hook = !say_hook in
  say_hook := (fun c s ->
      let name = match c with 
          None -> "_"
        | Some c -> 
            new_friend c;
            c.client_name in

      let list, _ = List2.cut
          !!max_dialog_history ((name, s) :: !dialog_history) in
      dialog_history :=  list;      
      
      List.iter (fun gui ->
          gui_say_hook gui name s
      ) !guis;
      old_hook c s  
  );
  
