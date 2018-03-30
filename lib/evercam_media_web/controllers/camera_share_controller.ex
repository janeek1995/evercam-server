defmodule EvercamMediaWeb.CameraShareController do
  use EvercamMediaWeb, :controller
  use PhoenixSwagger
  alias EvercamMediaWeb.CameraShareView
  alias EvercamMedia.Intercom
  alias EvercamMedia.Zoho

  swagger_path :show do
    get "/cameras/{id}/shares"
    summary "Returns the camera permitted users list."
    parameters do
      id :path, :string, "Unique identifier for camera.", required: true
      api_id :query, :string, "The Evercam API id for the requester."
      api_key :query, :string, "The Evercam API key for the requester."
    end
    tag "Shares"
    response 200, "Success"
    response 401, "Invalid API keys"
    response 403, "Forbidden camera access"
  end

  def show(conn, %{"id" => exid} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    user = User.by_username_or_email(params["user_id"])

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- user_exists(conn, params["user_id"], user),
         :ok <- user_can_list(conn, current_user, camera, params["user_id"])
    do
      shares =
        cond do
          user == nil && exid == "evercam-remembrance-camera" ->
            []
          user != nil && current_user != nil ->
            CameraShare.user_camera_share(camera, user)
          current_user != nil && caller_can_view(current_user, camera) ->
            CameraShare.camera_shares(camera)
          true ->
            []
        end
        conn
        |> render(CameraShareView, "index.json", %{camera_shares: shares, camera: camera, user: current_user})
    end
  end

  swagger_path :create do
    post "/cameras/{id}/shares"
    summary "Provides the camera rights to user."
    parameters do
      id :path, :string, "Unique identifier for camera.", required: true
      email :query, :string, "Share with Evercam registered user", required: true
      rights :query, :string, "", required: true, enum: ["snapshot","minimal+share","full"]
      message :query, :string, ""
      api_id :query, :string, "The Evercam API id for the requester."
      api_key :query, :string, "The Evercam API key for the requester."
    end
    tag "Shares"
    response 201, "Success"
    response 401, "Invalid API keys or Unauthorized"
    response 404, "Camera does not exist"
  end

  def create(conn, params) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(params["id"])
    email_array = ensure_list(params["email"])

    with :ok <- camera_exists(conn, params["id"], camera),
         :ok <- caller_has_permission(conn, caller, camera)
    do
      requester_ip = user_request_ip(conn)
      zoho_camera =
        case Zoho.get_camera(camera.exid) do
          {:ok, zoho_camera} -> zoho_camera
          _ -> %{}
        end

      fetch_shares =
        Enum.reduce(email_array, {[], [], [], Ecto.DateTime.utc}, fn email, {shares, share_requests, changes, datetime} = _acc ->
          next_datetime =
            datetime
            |> Ecto.DateTime.to_erl
            |> Calendar.DateTime.from_erl!("Etc/UTC", {123456, 6})
            |> Calendar.DateTime.advance!(2)
            |> NaiveDateTime.to_erl
            |> Ecto.DateTime.from_erl
          with {:found_user, sharee} <- ensure_user(email)
          do
            case CameraShare.create_share(camera, sharee, caller, params["rights"], params["message"]) do
              {:ok, camera_share} ->
                spawn(fn ->
                  unless caller == sharee do
                    send_email_notification(caller, camera, sharee.email, camera_share.message)
                  end
                  Camera.invalidate_user(sharee)
                  Camera.invalidate_camera(camera)
                  CameraActivity.log_activity(caller, camera, "shared", %{with: sharee.email, ip: requester_ip}, next_datetime)
                end)
                add_contact_to_zoho(Application.get_env(:evercam_media, :run_spawn), zoho_camera, sharee, caller.username)
                {[camera_share | shares], share_requests, changes, next_datetime}
              {:error, changeset} ->
                {shares, share_requests, [attach_email_to_message(changeset, email) | changes], next_datetime}
            end
          else
            {:not_found, email} ->
              case CameraShareRequest.create_share_request(camera, email, caller, params["rights"], params["message"]) do
                {:ok, camera_share_request} ->
                  spawn(fn ->
                    send_email_notification(caller, camera, email, camera_share_request.message, camera_share_request.key)
                    CameraActivity.log_activity(caller, camera, "shared", %{with: email, ip: requester_ip}, next_datetime)
                    Intercom.intercom_activity(Application.get_env(:evercam_media, :create_intercom_user), get_user_model(email), get_user_agent(conn), requester_ip, "Shared-Non-Registered")
                  end)
                  {shares, [camera_share_request | share_requests], changes, next_datetime}
                {:error, changeset} ->
                  {shares, share_requests, [attach_email_to_message(changeset, email) | changes], next_datetime}
              end
          end
        end)
      {total_shares, share_requests, errors, _} = fetch_shares
      conn
      |> put_status(:created)
      |> render(CameraShareView, "all_shares.json", %{shares: total_shares, share_requests: share_requests, errors: errors})
    end
  end

  defp add_contact_to_zoho(true, zoho_camera, user, user_id) when user_id in ["garda", "gardashared", "construction", "oldconstruction", "smartcities"] do
    spawn fn ->
      contact =
        case Zoho.get_contact(user.email) do
          {:ok, contact} -> contact
          _ ->
            {:ok, contact} = Zoho.insert_contact(user)
            Map.put(contact, "Full_Name", User.get_fullname(user))
        end
      Zoho.associate_camera_contact(contact, zoho_camera)
    end
  end
  defp add_contact_to_zoho(_mode, _camera, _user, _user_id), do: :noop

  defp ensure_list(email) do
    case is_binary(email) do
      true -> email |> List.wrap
      false -> email
    end
  end

  defp attach_email_to_message(changeset, email) do
    "#{Util.parse_changeset(changeset) |>  Map.values |> hd} (#{email})"
  end

  defp ensure_user(email) do
    case sharee = User.by_username_or_email(email) do
      nil -> {:not_found, email}
      %User{} -> {:found_user, sharee}
    end
  end

  swagger_path :update do
    patch "/cameras/{id}/shares"
    summary "Change the camera rights to user."
    parameters do
      id :path, :string, "Unique identifier for camera.", required: true
      email :query, :string, "Give shared user's email", required: true
      rights :query, :string, "", required: true, enum: ["snapshot","minimal+share","full"]
      api_id :query, :string, "The Evercam API id for the requester."
      api_key :query, :string, "The Evercam API key for the requester."
    end
    tag "Shares"
    response 200, "Success"
    response 400, "Invalid rights specified in request"
    response 401, "Invalid API keys or Unauthorized"
    response 404, "Camera does not exist or Share not found"
  end

  def update(conn, %{"id" => exid, "email" => email, "rights" => rights}) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    sharee = User.by_username_or_email(email)

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- caller_has_permission(conn, caller, camera),
         :ok <- sharee_exists(conn, email, sharee),
         {:ok, camera_share} <- share_exists(conn, sharee, camera)
    do
      share_changeset = CameraShare.changeset(camera_share, %{rights: rights})
      if share_changeset.valid? do
        CameraShare.update_share(sharee, camera, rights)
        CameraActivity.log_activity(caller, camera, "updated share", %{with: sharee.email, ip: user_request_ip(conn)})
        Camera.invalidate_user(sharee)
        Camera.invalidate_camera(camera)
        camera_share =
          camera_share
          |> Repo.preload([camera: :access_rights], force: true)
          |> Repo.preload([camera: [access_rights: :access_token]], force: true)
        conn
        |> render(CameraShareView, "show.json", %{camera_share: camera_share})
      else
        render_error(conn, 400, Util.parse_changeset(share_changeset))
      end
    end
  end

  swagger_path :delete do
    delete "/cameras/{id}/shares"
    summary "Delete the camera access."
    parameters do
      id :path, :string, "Unique identifier for camera.", required: true
      email :query, :string, "Give shared user's email", required: true
      api_id :query, :string, "The Evercam API id for the requester."
      api_key :query, :string, "The Evercam API key for the requester."
    end
    tag "Shares"
    response 200, "Success"
    response 401, "Invalid API keys or Unauthorized"
    response 404, "Camera does not exist or Share not found"
  end

  def delete(conn, %{"id" => exid, "email" => email}) do
    caller = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    sharee = User.by_username_or_email(email)

    with :ok <- camera_exists(conn, exid, camera),
         :ok <- sharee_exists(conn, email, sharee),
         :ok <- user_can_delete_share(conn, caller, sharee, camera),
         {:ok, _share} <- share_exists(conn, sharee, camera)
    do
      CameraShare.delete_share(sharee, camera)
      Camera.invalidate_user(sharee)
      Camera.invalidate_camera(camera)
      CameraActivity.log_activity(caller, camera, "stopped sharing", %{with: sharee.email, ip: user_request_ip(conn)})
      json(conn, %{})
    end
  end

  def shared_users(conn, params) do
    caller = conn.assigns[:current_user]

    cond do
      !caller ->
        render_error(conn, 401, "Unauthorized.")
      params["camera_id"] == "evercam-remembrance-camera" -> json(conn, %{})
      true ->
        shared_users =
          caller.id
          |> CameraShare.shared_users(params["camera_id"])
          |> Enum.map(fn(u) -> %{email: u.user.email, name: User.get_fullname(u.user)} end)
          |> Enum.sort
          |> Enum.uniq
        json(conn, shared_users)
    end
  end

  defp camera_exists(conn, camera_exid, nil), do: render_error(conn, 404, "The #{camera_exid} camera does not exist.")
  defp camera_exists(_conn, _camera_exid, _camera), do: :ok

  defp user_exists(_conn, nil, nil), do: :ok
  defp user_exists(conn, user_id, nil), do: render_error(conn, 404, "User '#{user_id}' does not exist.")
  defp user_exists(_conn, _user_id, _user), do: :ok

  defp caller_has_permission(conn, user, camera) do
    cond do
      Permission.Camera.can_edit?(user, camera) -> :ok
      Permission.Camera.can_share?(user, camera) -> :ok
      true -> render_error(conn, 401, "Unauthorized.")
    end
  end

  defp caller_can_view(user, camera) do
    Permission.Camera.can_edit?(user, camera) || Permission.Camera.can_share?(user, camera)
  end

  defp user_can_list(_conn, _user, _camera, nil), do: :ok
  defp user_can_list(conn, user, camera, user_id) do
    user_id = String.downcase(user_id)

    if !Permission.Camera.can_list?(user, camera) && (user.email != user_id && user.username != user_id) do
      render_error(conn, 401, "Unauthorized.")
    else
      :ok
    end
  end

  defp user_can_delete_share(conn, caller, sharee, camera) do
    cond do
      Permission.Camera.can_list?(caller, camera) -> :ok
      caller == sharee -> :ok
      true -> render_error(conn, 401, "Unauthorized.")
    end
  end

  defp sharee_exists(conn, email, nil), do: render_error(conn, 404, "Sharee '#{email}' not found.")
  defp sharee_exists(_conn, _email, _sharee), do: :ok

  defp share_exists(conn, sharee, camera) do
    case CameraShare.by_user_and_camera(camera.id, sharee.id) do
      nil -> render_error(conn, 404, "Share not found.")
      %CameraShare{} = camera_share -> {:ok, camera_share}
    end
  end

  defp send_email_notification(user, camera, to_email, message) do
    try do
      Task.start(fn ->
        EvercamMedia.UserMailer.camera_shared_notification(user, camera, to_email, message)
      end)
    catch _type, error ->
      Util.error_handler(error)
    end
  end

  defp send_email_notification(user, camera, to_email, message, share_request_key) do
    try do
      Task.start(fn ->
        EvercamMedia.UserMailer.camera_share_request_notification(user, camera, to_email, message, share_request_key)
      end)
    catch _type, error ->
      Util.error_handler(error)
    end
  end

  defp get_user_model(email) do
    %User{
      username: "",
      firstname: "",
      lastname: "",
      email: email,
      created_at: Ecto.DateTime.utc
    }
  end
end
