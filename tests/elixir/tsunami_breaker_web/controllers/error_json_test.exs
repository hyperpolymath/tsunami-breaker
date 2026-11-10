# SPDX-License-Identifier: MPL-2.0
defmodule TsunamiBreakerWeb.ErrorJSONTest do
  use TsunamiBreakerWeb.ConnCase, async: true

  test "renders 404" do
    assert TsunamiBreakerWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert TsunamiBreakerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
