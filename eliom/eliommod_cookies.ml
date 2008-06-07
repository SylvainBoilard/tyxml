(* Ocsigen
 * http://www.ocsigen.org
 * Module eliommod_cookies.ml
 * Copyright (C) 2007 Vincent Balat
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** Cookie management                                                       *)

open Lwt

(*****************************************************************************)
let make_new_cookie_value =
    let rng = Cryptokit.Random.device_rng "/dev/urandom"
    and to_hex = Cryptokit.Hexa.encode () in
    fun () ->
        let random_part =
            let random_number = Cryptokit.Random.string rng 20 in
            Cryptokit.transform_string to_hex random_number
        and sequential_part =
            Printf.sprintf "%Lx" (Int64.bits_of_float (Unix.gettimeofday ())) in
        random_part ^ sequential_part


(*

This function generates a new session ID.  Session IDs are 224 bits long,
and are returned as a string of 56 hexadecimal characters.

The session ID is produced from the concatenation of two components: a
160-bit random sequence obtained from /dev/urandom, and a 64-bit sequential
component derived from the system clock.  The former is supposed to prevent
session spoofing.  The assumption is that given the high cryptographic quality
of /dev/urandom, it is impossible for an attacker to deduce the sequence of
random numbers produced.  As for the latter component, it exists to prevent
a theoretical (though infinitesimally unlikely) session ID collision if the
server were to be restarted.
*)




(*****************************************************************************)
(* cookie manipulation *)

(** look in table to find if the session cookies sent by the browser
    correspond to existing (and not closed) sessions *)
let get_cookie_info now sitedata
    service_cookies
    data_cookies
    persistent_cookies
    : 'a Eliom_common.cookie_info * 'b list =

  (* get info about service session cookies: *)
  let (servoktable, servfailedlist) =
    Ocsigen_http_frame.Cookievalues.fold
      (fun name value (oktable, failedlist) ->
        try
          let fullsessname, ta, expref, timeout_ref, sessgrpref =
            Eliom_common.SessionCookies.find
              sitedata.Eliom_common.session_services value
          in
          Eliommod_sessiongroups.Serv.up value !sessgrpref;
          match !expref with
          | Some t when t < now ->
              (* session expired by timeout *)
              Eliom_common.SessionCookies.remove
                sitedata.Eliom_common.session_services value;
              ((Ocsigen_http_frame.Cookievalues.add
                  name
                  (Some value          (* value sent by the browser *),
                   ref Eliom_common.SCData_session_expired
                                       (* ask the browser
                                          to remove the cookie *))
                  oktable),
               name::failedlist)
          | _ -> ((Ocsigen_http_frame.Cookievalues.add
                     name
                     (Some value        (* value sent by the browser *),
                      ref
                        (Eliom_common.SC
                           {Eliom_common.sc_value= value  (* value *);
                            Eliom_common.sc_table= ref ta (* the table of session services *);
                            Eliom_common.sc_timeout= timeout_ref (* user timeout ref *);
                            Eliom_common.sc_exp= expref  (* expiration date (server side) *);
                            Eliom_common.sc_cookie_exp=
                            ref Eliom_common.CENothing
                              (* cookie expiration date to send
                                 to the browser *);
                            Eliom_common.sc_session_group= sessgrpref}))
                     oktable),
                  failedlist)
        with Not_found ->
          ((Ocsigen_http_frame.Cookievalues.add
              name
              (Some value                 (* value sent by the browser *),
               ref Eliom_common.SCData_session_expired
                                          (* ask the browser
                                             to remove the cookie *))
              oktable),
           name::failedlist)
      )
      service_cookies
      (Ocsigen_http_frame.Cookievalues.empty, [])
  in

  (* get info about "in memory" data session cookies: *)
  let dataoktable =
    Ocsigen_http_frame.Cookievalues.map
      (fun value ->
        lazy
          (try
            let fullsessname, expref, timeout_ref, sessgrpref =
              Eliom_common.SessionCookies.find
                sitedata.Eliom_common.session_data value
            in
            Eliommod_sessiongroups.Serv.up value !sessgrpref;
            match !expref with
            | Some t when t < now ->
                (* session expired by timeout *)
                sitedata.Eliom_common.remove_session_data value;
                Eliom_common.SessionCookies.remove
                  sitedata.Eliom_common.session_data value;
                (Some value                 (* value sent by the browser *),
                 ref Eliom_common.SCData_session_expired
                                            (* ask the browser
                                               to remove the cookie *))
            | _ ->
                (Some value        (* value sent by the browser *),
                 ref
                   (Eliom_common.SC
                      {Eliom_common.dc_value= value       (* value *);
                       Eliom_common.dc_timeout= timeout_ref (* user timeout ref *);
                       Eliom_common.dc_exp= expref      (* expiration date (server side) *);
                       Eliom_common.dc_cookie_exp=
                       ref Eliom_common.CENothing
                         (* cookie expiration date to send
                            to the browser *);
                       Eliom_common.dc_session_group= sessgrpref}
                   )
                )
          with Not_found ->
            (Some value                  (* value sent by the browser *),
             ref Eliom_common.SCData_session_expired
                                         (* ask the browser
                                            to remove the cookie *))))
      data_cookies
  in


  (* *** get info about persistent session cookies: *)
  let persoktable =
    Ocsigen_http_frame.Cookievalues.map
      (fun value ->
        lazy
          (catch
             (fun () ->
               Ocsipersist.find
                 Eliom_common.persistent_cookies_table value >>=
               fun (fullsessname, persexp, perstimeout, sessgrp) ->

                 Eliommod_sessiongroups.Pers.up value sessgrp >>= fun () ->
                 match persexp with
                 | Some t when t < now ->
                     (* session expired by timeout *)
                     Eliom_common.remove_from_all_persistent_tables
                       value >>= fun () ->
                       return
                         (Some (value         (* value at the beginning
                                                 of the request *),
                                perstimeout   (* user persistent timeout
                                                 at the beginning
                                                 of the request *),
                                persexp       (* expiration date (server)
                                                 at the beginning
                                                 of the request *),
                                sessgrp       (* session group at beginning *)),
                          ref Eliom_common.SCData_session_expired
                                              (* ask the browser to
                                                 remove the cookie *))
                 | _ ->
                     return
                       (Some (value        (* value at the beginning
                                              of the request *),
                              perstimeout  (* user persistent timeout
                                              at the beginning
                                              of the request *),
                              persexp      (* expiration date (server)
                                              at the beginning
                                              of the request *),
                              sessgrp      (* session group at beginning *)),
                        (ref
                           (Eliom_common.SC
                              {Eliom_common.pc_value= value
                                 (* value *);
                               Eliom_common.pc_timeout= ref perstimeout
                                 (* user persistent timeout ref *);
                               Eliom_common.pc_cookie_exp=
                               ref Eliom_common.CENothing
                                 (* persistent cookie expiration
                                    date ref to send to the
                                    browser *);
                               Eliom_common.pc_session_group= ref sessgrp
                             })))
             )
             (function
               | Not_found ->
                   return
                     (Some (value         (* value at the beginning
                                             of the request *),
                            Eliom_common.TGlobal
                                          (* user persistent timeout
                                             at the beginning
                                             of the request *),
                            Some 0.       (* expiration date (server)
                                             at the beginning
                                             of the request *),
                            None          (* session group at beginning *)),
                      ref Eliom_common.SCData_session_expired
                                          (* ask the browser
                                             to remove the cookie *))
               | e -> fail e)
          )
      )
      persistent_cookies (* the persistent cookies sent by the request *)

  in
  ((ref servoktable, ref dataoktable, ref persoktable),
   servfailedlist)


(*****************************************************************************)

(* table cookie -> session table *)
let new_service_cookie_table () :
    Eliom_common.tables Eliom_common.servicecookiestable =
  Eliom_common.SessionCookies.create 1000

let new_data_cookie_table () : Eliom_common.datacookiestable =
  Eliom_common.SessionCookies.create 1000




(*****************************************************************************)
(* Create the table of cookies to send to the browser or to unset            *)
(* (from cookie_info)                                                        *)

let compute_session_cookies_to_send
    sitedata
    (service_cookie_info,
     data_cookie_info,
     pers_cookies_info) endlist =
  let getservvexp name (old, newi) =
    return
      (let newinfo =
        match !newi with
        | Eliom_common.SCNo_data
        | Eliom_common.SCData_session_expired -> None
        | Eliom_common.SC c ->
            Some (c.Eliom_common.sc_value,
                  !(c.Eliom_common.sc_cookie_exp))
      in (name, old, newinfo))
  in
  let getdatavexp name v =
    if Lazy.lazy_is_val v
    then
      return
        (let (old, newi) = Lazy.force v in
        let newinfo =
          match !newi with
          | Eliom_common.SCNo_data
          | Eliom_common.SCData_session_expired -> None
          | Eliom_common.SC c ->
              Some (c.Eliom_common.dc_value,
                    !(c.Eliom_common.dc_cookie_exp))
        in (name, old, newinfo))
    else fail Not_found
  in
  let getpersvexp name v =
    if Lazy.lazy_is_val v
    then
      Lazy.force v >>= fun (old, newi) ->
      return
        (let oldinfo =
          match old with
            | None -> None
            | Some (v, _, _, _) -> Some v
         in
         let newinfo =
           match !newi with
             | Eliom_common.SCNo_data
             | Eliom_common.SCData_session_expired -> None
             | Eliom_common.SC c ->
                 Some (c.Eliom_common.pc_value,
                       !(c.Eliom_common.pc_cookie_exp))
         in (name, oldinfo, newinfo))
    else fail Not_found
  in
  let ch_exp = function
    | Eliom_common.CENothing
    | Eliom_common.CEBrowser -> None
    | Eliom_common.CESome a -> Some a
  in
  let aux f cookiename tab2 cooktab =
    cooktab >>= fun cooktab ->
    Ocsigen_http_frame.Cookievalues.fold
      (fun name value beg ->
        beg >>= fun beg ->
        catch
          (fun () ->
            f name value >>= fun (name, old, newc) ->
            return
              (match old, newc with
              | None, None -> beg
              | Some _, None ->
                  Ocsigen_http_frame.add_cookie
                    sitedata.Eliom_common.site_dir
                    (Eliom_common.make_full_cookie_name cookiename name)
                    Ocsigen_http_frame.OUnset
                    beg
                  (* the path is always site_dir because the cookie cannot
                     have been unset by a service outside
                     this site directory *)
              | None, Some (v, exp) ->
                  Ocsigen_http_frame.add_cookie
                    sitedata.Eliom_common.site_dir
                    (Eliom_common.make_full_cookie_name cookiename name)
                    (Ocsigen_http_frame.OSet (ch_exp exp, v))
                    beg
              | Some oldv, Some (newv, exp) ->
                  if exp = Eliom_common.CENothing && oldv = newv
                  then beg
                  else Ocsigen_http_frame.add_cookie
                      sitedata.Eliom_common.site_dir
                      (Eliom_common.make_full_cookie_name cookiename name)
                      (Ocsigen_http_frame.OSet (ch_exp exp, newv))
                      beg
              )
          )
          (function
            | Not_found -> return beg
            | e -> fail e)
      )
      tab2
      (return cooktab)
  in
  aux getpersvexp Eliom_common.persistentcookiename !pers_cookies_info
    (aux getdatavexp Eliom_common.datacookiename !data_cookie_info
       (aux getservvexp Eliom_common.servicecookiename !service_cookie_info
          (return endlist)))


let compute_cookies_to_send = compute_session_cookies_to_send


(* add a list of Eliom's cookies to an Ocsigen_http_frame cookie table *)
let add_cookie_list_to_send sitedata l t =
  let change_pathopt = function
    | None -> sitedata.Eliom_common.site_dir
          (* Not possible to set a cookie for another site (?) *)
    | Some p -> sitedata.Eliom_common.site_dir@p
  in
  List.fold_left
    (fun t v ->
      match v with
      | Eliom_common.Set (upo, expo, n, v) ->
          Ocsigen_http_frame.add_cookie (change_pathopt upo) n
            (Ocsigen_http_frame.OSet (expo, v)) t
      | Eliom_common.Unset (upo, n) ->
          Ocsigen_http_frame.add_cookie (change_pathopt upo) n Ocsigen_http_frame.OUnset t
    )
    t
    l


let compute_new_ri_cookies'
    now
    ripath
    ricookies
    cookies_set_by_page =

  let prefix upo p = match upo with
    | None -> true
    | Some path ->
        Ocsigen_lib.list_is_prefix
          (Ocsigen_lib.remove_slash_at_beginning path)
          (Ocsigen_lib.remove_slash_at_beginning p)
  in
  List.fold_left
    (fun tab v ->
      match v with
      | Eliom_common.Set (upo, Some t, n, v)
        when t>now && prefix upo ripath ->
          Ocsigen_http_frame.Cookievalues.add n v tab
      | Eliom_common.Set (upo, None, n, v) when prefix upo ripath ->
          Ocsigen_http_frame.Cookievalues.add n v tab
      | Eliom_common.Set (upo, _, n, _)
      | Eliom_common.Unset (upo, n) when prefix upo ripath ->
          Ocsigen_http_frame.Cookievalues.remove n tab
      | _ -> tab
    )
    ricookies
    cookies_set_by_page


(** Compute new ri.ri_cookies value
    from an old ri.ri_cookies and all_cookie_info
    as if it had been sent by the browser *)
let compute_new_ri_cookies
    now
    ripath
    ricookies
    (service_cookie_info, data_cookie_info, pers_cookie_info)
    cookies_set_by_page =

  let ric =
    compute_new_ri_cookies' now ripath ricookies cookies_set_by_page
  in
  let ric =
    Ocsigen_http_frame.Cookievalues.fold
      (fun n (_, v) beg ->
        let n = Eliom_common.make_full_cookie_name
            Eliom_common.servicecookiename n
        in
        match !v with
        | Eliom_common.SCData_session_expired
        | Eliom_common.SCNo_data -> Ocsigen_http_frame.Cookievalues.remove n beg
        | Eliom_common.SC c ->
            Ocsigen_http_frame.Cookievalues.add n c.Eliom_common.sc_value beg
      )
      !service_cookie_info
      ric
  in
  let ric =
    Ocsigen_http_frame.Cookievalues.fold
      (fun n v beg ->
        let n = Eliom_common.make_full_cookie_name
            Eliom_common.datacookiename n
        in
        if Lazy.lazy_is_val v
        then
          let (_, v) = Lazy.force v in
          match !v with
          | Eliom_common.SCData_session_expired
          | Eliom_common.SCNo_data -> Ocsigen_http_frame.Cookievalues.remove n beg
          | Eliom_common.SC c ->
              Ocsigen_http_frame.Cookievalues.add n c.Eliom_common.dc_value beg
        else beg
      )
      !data_cookie_info
      ric
  in
  let ric =
    Ocsigen_http_frame.Cookievalues.fold
      (fun n v beg ->
        let n =
          Eliom_common.make_full_cookie_name
            Eliom_common.persistentcookiename n
        in
        beg >>= fun beg ->
        if Lazy.lazy_is_val v
        then
          Lazy.force v >>= fun (_, v) ->
          match !v with
          | Eliom_common.SCData_session_expired
          | Eliom_common.SCNo_data ->
              return (Ocsigen_http_frame.Cookievalues.remove n beg)
          | Eliom_common.SC c ->
              return (Ocsigen_http_frame.Cookievalues.add n
                        c.Eliom_common.pc_value beg)
        else return beg
      )
      !pers_cookie_info
      (return ric)
  in
  ric
