defmodule CubiHelloTest do
  use ExUnit.Case, async: true

  test "serves the welcome page with the version" do
    resp = Req.get!("http://127.0.0.1:4002/")

    assert resp.status == 200
    assert resp.body == "Welcome to Cubi\nVersion: 0.1.0\n"
    assert ["text/plain" <> _] = resp.headers["content-type"]
  end

  test "anything else is a 404" do
    assert Req.get!("http://127.0.0.1:4002/nope").status == 404
  end
end
