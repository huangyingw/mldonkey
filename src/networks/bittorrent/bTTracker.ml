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

open Md4
open Options
open Printf2

open BasicSocket
  
open CommonGlobals
  
open BTOptions
open BTTypes
open Bencode
  
let encode_torrent torrent =
  
  let npieces = Array.length torrent.torrent_pieces in
  let pieces = String.create (20 * npieces) in
  for i = 0 to npieces - 1 do
    String.blit (Sha1.direct_to_string torrent.torrent_pieces.(i)) 0
      pieces (i*20) 20
  done;

  let encode_file (filename, size) =
    Dictionary [
      String "path", List (List.map 
          (fun s -> String s)(Filepath.string_to_path '/' filename));
      String "length", Int size;
    ]
  in
  
  let files = 
    match torrent.torrent_files with 
      [] ->       
        String "length", Int torrent.torrent_length
    | _ ->
        String "files", 
        List (List.map encode_file torrent.torrent_files)
  in
  
  let info =
    Dictionary [
      files;
      String "name", String torrent.torrent_name;
      String "piece length", Int torrent.torrent_piece_size;
      String "pieces", String pieces;
    ]
  in
  
  let info_encoded = Bencode.encode info in
  let file_id = Sha1.string info_encoded in
  file_id, 
  Dictionary [
    String "announce", String torrent.torrent_announce;
    String "info", info;
  ]
  
let chunk_size = Int64.of_int (256 * 1024)  
    
let make_torrent filename = 
  let basename = Filename.basename filename in
  let announce = Printf.sprintf "http://%s:%d/tracker"
      (Ip.to_string (CommonOptions.client_ip None)) !!tracker_port in
  let files, t =
    if Unix2.is_directory filename then
      let rec iter_directory list dirname =
        let files = Unix2.list_directory (Filename.concat filename dirname) in
        iter_files list dirname files
      
      and iter_files list dirname files =
        match files with
          [] -> list
        | file :: tail ->
            let basename = Filename.concat dirname file in
            let fullname = Filename.concat filename basename in
            let left =
              if Unix2.is_directory fullname then
                iter_directory list basename
              else
                (basename, Unix32.getsize fullname) :: list
            in
            iter_files left dirname tail
      in
      let files = iter_directory [] "" in
      let t = Unix32.create_multifile filename Unix32.ro_flag 0o666 files in
      files, t
    else
      [], Unix32.create_ro filename
  in
  
  Unix32.flush_fd t;
  let length = Unix32.getsize64 t in
  let npieces = 1+ Int64.to_int ((length -- one) // chunk_size) in
  let pieces = Array.create npieces Sha1.null in
  for i = 0 to npieces - 1 do
    let begin_pos = chunk_size ** i in
    
    let end_pos = begin_pos ++ chunk_size in
    let end_pos = 
      if end_pos > length then length else end_pos in
    
    let sha1 = Sha1.digest_subfile t
        begin_pos (end_pos -- begin_pos) in
    pieces.(i) <- sha1
  done;
  
  {
    torrent_name = basename;
    torrent_length = length;
    torrent_announce = announce;
    torrent_piece_size = chunk_size;
    torrent_files = files;
    torrent_pieces = pieces;
  }

let generate_torrent filename =
  let torrent = make_torrent filename in
  let file_id, encoded = encode_torrent torrent in
  let encoded = Bencode.encode encoded in
  File.from_string (Printf.sprintf "%s.torrent" filename) encoded 


open Http_server

type tracker_peer = {
    peer_id : Sha1.t;
    mutable peer_ip : Ip.t;
    mutable peer_port : int;
    mutable peer_active : int;
  }
  
type tracker = {
    mutable tracker_table : (Sha1.t, tracker_peer) Hashtbl.t;
    mutable tracker_peers1 : tracker_peer list;
    mutable tracker_peers2 : tracker_peer list;
  }
  
let tracked_files = Hashtbl.create 13
  
let http_handler t r =
  match r.get_url.Url.file with
    "/tracker" ->
      begin
        try
          
          let args = r.get_url.Url.args in
          let info_hash = ref Sha1.null in
          let peer_id = ref Sha1.null in
          let port = ref 0 in
          let uploaded = ref zero in
          let downloaded = ref zero in
          let left = ref zero in
          let event = ref "" in
          List.iter (fun (name, arg) ->
              match name with
              | "info_hash" -> info_hash := Sha1.direct_of_string arg
              | "peer_id" -> peer_id := Sha1.direct_of_string arg
              | "port" -> port := int_of_string arg
              | "uploaded" -> uploaded := Int64.of_string name
              | "downloaded" -> downloaded := Int64.of_string name
              | "left" -> left  := Int64.of_string name
              | "event" -> event := arg
              | _ -> lprintf "BTTracker: Unexpected arg %s\n" name
          ) args;
          
          let tracker = 
            try 
              Hashtbl.find tracked_files !info_hash 
            with Not_found ->
                let tracker = {
                    tracker_table = Hashtbl.create 13;
                    tracker_peers1 = [];
                    tracker_peers2 = [];
                  } in
                Hashtbl.add tracked_files !info_hash tracker;
                tracker
          in
          
          let peer = 
            try 
              let peer = 
                Hashtbl.find tracker.tracker_table !peer_id
              in
              peer.peer_ip <- TcpBufferedSocket.peer_ip r.sock;
              peer.peer_port <- !port;
              peer.peer_active <- last_time ();
              peer
            with _ -> 
                let peer = 
                  { 
                    peer_id = !peer_id;
                    peer_ip = TcpBufferedSocket.peer_ip r.sock;
                    peer_port = !port;
                    peer_active = last_time ();
                  } in
                Hashtbl.add tracker.tracker_table !peer_id peer;
                peer
          in
          match !event with
            "completed" | "stopped" -> 
(* Don't return anything *)
              ()
          | _ ->
(* Return the 20 best peers *)
              let head, tail = List2.cut 20 tracker.tracker_peers1 in
              tracker.tracker_peers1 <- tail;
              let head = 
                let n = List.length head in
                if n < 20 then begin
                    tracker.tracker_peers1 <- tracker.tracker_peers2;
                    tracker.tracker_peers2 <- [];
                    let head2, tail = List2.cut (20-n) tracker.tracker_peers1
                    in
                    tracker.tracker_peers1 <- tail;
                    head @ head2
                  end
                else 
                  head 
              in
              tracker.tracker_peers2 <- head @ tracker.tracker_peers2;
(* reply by sending [head] *)
              
        with e ->
            lprintf "BTTracker: Exception %s\n" (Printexc2.to_string e)
      end
  | _ ->  
      lprintf "BTTracker: Unexpected request [%s]\n" 
      (Url.to_string true r.get_url)
      
let start_tracker () = 
  let config = {
      bind_addr = Unix.inet_addr_any ;
      port = !!tracker_port;
      requests = [];
      addrs = [ Ip.of_string "255.255.255.255" ];
      base_ref = "";
      default = http_handler;      
    } in
  let sock = TcpServerSocket.create "BT tracker"
      Unix.inet_addr_any !!tracker_port (Http_server.handler config) in
  ()

let clean_tracker_timer () =
  let time_threshold = last_time () - 3600 in
  Hashtbl.iter (fun _ tracker ->
      let list = ref [] in
      let old_peers = ref [] in
      Hashtbl.iter (fun _ peer -> 
          if peer.peer_active < time_threshold then
            old_peers := peer :: !old_peers
          else
          if Ip.valid peer.peer_ip && Ip.reachable peer.peer_ip then
            list := peer :: !list) 
      tracker.tracker_table;
      List.iter (fun p ->
          Hashtbl.remove tracker.tracker_table p.peer_id
      ) !old_peers;
      tracker.tracker_peers1 <- 
        List.sort (fun p1 p2 -> - compare p1.peer_active p2.peer_active) !list;
      tracker.tracker_peers2 <- [];
  ) tracked_files