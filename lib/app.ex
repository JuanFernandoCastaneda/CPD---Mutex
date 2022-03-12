defmodule App do

  @registered_apps :registered_apps
  @app_counter :app_counter
  @current_requests :current_requests
  @service_counter :service_counter
  @current_service :current_service

  @doc """
  Function that starts the basic functionality of the app by initiating the links of all
  the agents involved. The app does not work before this.
  """
  def start() do
    Supervisor.start_link([{Mutex, name: MyMutex}], strategy: :one_for_one)
    Agent.start_link(fn -> [] end, name: @registered_apps)
    Agent.start_link(fn -> 1 end, name: @app_counter)
    Agent.start_link(fn -> [] end, name: @current_requests)
    Agent.start_link(fn -> 1 end, name: @service_counter)
    Agent.start_link(fn -> nil end, name: @current_service)
    "App started"
  end

  @doc """
  Function that registers an app for the user. The first parameter is the name of the service
  and the second one is the time that the requests for that app will be alive (it could've been
  arbitrarily decided to autogenerate that number).
  """
  def register_app(name, service_alive_time) do
    lock_counter = Mutex.await(MyMutex, @app_counter)
    id = Agent.get_and_update(@app_counter, fn app_counter -> {app_counter, app_counter + 1} end)
    Mutex.release(MyMutex, lock_counter)

    lock_app = Mutex.await(MyMutex, @registered_apps)
    result = Agent.update(@registered_apps, fn apps -> 
    [%{:id => id, :name => name, :service_alive_time => service_alive_time} | apps] 
    end)
    Mutex.release(MyMutex, lock_app)
    result
  end

  @doc """
  Emulates the behaviour of an app by spawning a process with a function that does not end
  until the app has been unregistered. The parameter is the id of the app to simulate the behaviour
  for.
  """
  def app_behaviour(id) do
    spawn(fn -> send_requests_until_unregistered(id) end)
    "App " <> to_string(id) <> " sending requests until unregistered"
  end

  @doc """
  Function that recursively makes petition in the name of an app id until it cannot find 
  the app in the registered apps. The parameter is the id of the app to send the requests for.
  The parameters of the request are generated statically for simplicity.
  """
  def send_requests_until_unregistered(id) do
    app = Agent.get(@registered_apps, fn apps -> apps end)
    |> Enum.find(fn app -> app[:id] == id end)

    if app == nil do
      "Return"
    else
      register_request(app[:id], app[:name], "Express", 10, "Debit")
      :timer.sleep(500 + :rand.uniform(1000))
      send_requests_until_unregistered(id)
    end
  end
  
  def get_registered_apps() do
    Agent.get(@registered_apps, fn apps -> apps end)
  end

  @doc """
  Unregister an app and kill all the requests it had. All except for the current service one.
  The parameter is the id of the app to be unregistered.
  """
  def unregister_app(id) do
    lock_requests = Mutex.await(MyMutex, @current_requests)
    Agent.update(@current_requests, fn requests ->
      Enum.filter(requests, fn request -> request[:app_id] != id end) 
    end)
    Mutex.release(MyMutex, lock_requests)

    lock_apps = Mutex.await(MyMutex, @registered_apps)
    result = Agent.get_and_update(@registered_apps, fn apps ->
      filtered_apps = Enum.filter(apps, fn app -> app[:id] != id end)
      {"App with id " <> to_string(id) <> " was removed if existed", filtered_apps}
    end)
    Mutex.release(MyMutex, lock_apps)

    result
  end

  @doc """
  Function that registers a request for an app. The first parameter is the app's id, the second
  is the name of the user, the third is the type of the service, the forth the price and the fifth
  the payment method.
  """
  def register_request(app_id, user_name, service_type, price, payment_method) do
    lock_apps = Mutex.await(MyMutex, @registered_apps)
    requesting_app = Agent.get(@registered_apps, fn apps -> apps end)
    |> Enum.find(fn app -> app[:id] == app_id end)
    Mutex.release(MyMutex, lock_apps)

    cond do
      requesting_app == nil ->
        "The requesting app does not exists"
      Agent.get(@current_service, fn service -> service end) != nil ->
        "There is already a service taking place"
      true ->
        lock_scounter = Mutex.await(MyMutex, @service_counter)
        request_id = Agent.get_and_update(@service_counter, fn service_counter -> {service_counter, service_counter + 1} end)
        Mutex.release(MyMutex, lock_scounter)

        lock_requests = Mutex.await(MyMutex, @current_requests)
        Agent.update(@current_requests, 
        fn services -> [
          %{:id => request_id, :app_id => app_id, :user_name => user_name, :service_type => service_type, 
          :price => price, :payment_method => payment_method, 
          :expire_time => (:os.system_time(:second) + requesting_app[:service_alive_time])} 
          | services]
        end)
        Mutex.release(MyMutex, lock_requests)
        update_and_get_requests()
    end
  end

  @doc """
  Function that retrieves the current requests, filters the ones that have already expired, and
  then both updates the value on the Agent and then turns the value to the user.
  """
  def update_and_get_requests do
    lock_requests = Mutex.await(MyMutex, @current_requests)
    result = Agent.get_and_update(@current_requests, 
    fn services -> 
      updated_services = Enum.filter(services, fn service -> service[:expire_time] > :os.system_time(:second) end)
      {updated_services, updated_services}
    end)
    Mutex.release(MyMutex, lock_requests)
    result
  end

  @doc """
  Function that allows the aggregator to choose one service of the list of active ones.
  Throws an error message if the current service does not exists (maybe anymore) or 
  if there is a service already taking place, even if it is not necessary.
  The parameter is the id of the service to take.
  """    
  def choose_service(id) do
    new_service = update_and_get_requests()
    |> Enum.find(fn request -> request[:id] == id end)

    cond do
      update_and_get_current_service() != nil ->
        "There is a service already on place"
      new_service == nil ->
        "Chosen service does not exists"
      true ->
        lock_current = Mutex.await(MyMutex, @current_service)
        Agent.update(@current_service, fn _ -> 
        new_service |> Map.merge(generate_service_specs())
        |> Map.delete(:expire_time)
        end)
        Mutex.release(MyMutex, lock_current)
    end
  end

  @doc """
  Function that randomly generates the missing specifications for the service.
  It is generated statically for the simplicity.
  """
  defp generate_service_specs() do
    %{:estimated_end => :os.system_time(:second) + :rand.uniform(20) + 10, 
    :pickup => "Pickup place",
    :drop_off => "Drop-off place"}
  end

  @doc """
  Function that updates the value of the current service by comparing its estimated end 
  time with the current os time before retrieving the value to the user.
  """
  def update_and_get_current_service do
    lock_current = Mutex.await(MyMutex, @current_service)
    current = Agent.get_and_update(@current_service,
    fn service -> 
      if service[:estimated_end] > :os.system_time(:second) do
        {service, service}
      else
        {nil, nil}
      end
    end)
    Mutex.release(MyMutex, lock_current)
    current
  end

end
