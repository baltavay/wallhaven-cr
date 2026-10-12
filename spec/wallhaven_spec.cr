require "spec"
require "../src/wallhaven"

# The search request is the app's contract with wallhaven.cc: a wrong bitmask or
# a missed parameter silently returns the wrong wallpapers.
describe Wallhaven do
  describe ".params" do
    it "encodes every filter in the documented form" do
      query = Wallhaven::Query.new(
        q: "wrestling",
        categories: "110",
        purity: "011",
        sorting: "toplist",
        order: "desc",
        top_range: "1M",
        at_least: "2560x1440",
        resolutions: "3840x2160,1920x1080",
        ratios: "landscape",
        colors: "#b33838",
        page: 3,
        seed: "abc")
      params = Wallhaven.params(query, "key123")

      params["q"].should eq "wrestling"
      params["categories"].should eq "110"
      params["purity"].should eq "011"
      params["sorting"].should eq "toplist"
      params["order"].should eq "desc"
      params["topRange"].should eq "1M"
      params["atleast"].should eq "2560x1440"
      params["resolutions"].should eq "3840x2160,1920x1080"
      params["ratios"].should eq "landscape"
      params["colors"].should eq "b33838" # leading '#' must be stripped
      params["page"].should eq "3"
      params["seed"].should eq "abc"
      params["apikey"].should eq "key123"
    end

    it "omits empty filters and falls back to safe defaults" do
      params = Wallhaven.params(Wallhaven::Query.new, nil)

      params["q"]?.should be_nil
      params["atleast"]?.should be_nil
      params["colors"]?.should be_nil
      params["topRange"]?.should be_nil
      params["apikey"]?.should be_nil
      params["categories"].should eq "111"
      params["purity"].should eq "100"
      params["sorting"].should eq "date_added"
      params["order"].should eq "asc"
      params["page"].should eq "1"
    end
  end

  describe "#wallpaper_from" do
    it "keeps the fields the grid and the detail panel need" do
      item = JSON.parse(<<-JSON)
      {
        "id": "k8lkrm",
        "url": "https://wallhaven.cc/w/k8lkrm",
        "path": "https://w.wallhaven.cc/full/k8/wallhaven-k8lkrm.jpg",
        "resolution": "3200x1800",
        "category": "anime",
        "purity": "sfw",
        "colors": ["#000000", "#424153"],
        "thumbs": {"small": "https://th.wallhaven.cc/small/k8/k8lkrm.jpg",
                   "original": "https://th.wallhaven.cc/orig/k8/k8lkrm.jpg"}
      }
      JSON

      wallpaper = Wallhaven.new.wallpaper_from(item)

      wallpaper.id.should eq "k8lkrm"
      wallpaper.source.should eq "wallhaven"
      wallpaper.url.should eq "https://w.wallhaven.cc/full/k8/wallhaven-k8lkrm.jpg"
      wallpaper.page_url.should eq "https://wallhaven.cc/w/k8lkrm"
      wallpaper.resolution.should eq "3200x1800"
      wallpaper.category.should eq "anime"
      wallpaper.purity.should eq "sfw"
      wallpaper.colors.should eq ["#000000", "#424153"]
      wallpaper.remote_thumb.should eq "https://th.wallhaven.cc/small/k8/k8lkrm.jpg"
    end
  end
end
