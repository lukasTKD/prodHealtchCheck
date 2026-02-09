<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>

<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "application/json";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        string group = Request.QueryString["group"];

        // Walidacja nazwy grupy - tylko litery
        if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
        {
            group = "DCI";
        }

        string jsonPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\serverHealth_" + group + ".json";

        try
        {
            if (File.Exists(jsonPath))
            {
                string json = File.ReadAllText(jsonPath);
                Response.Write(json);
            }
            else
            {
                Response.StatusCode = 404;
                Response.Write("{\"error\":\"Brak danych dla grupy: " + group + "\"}");
            }
        }
        catch (Exception ex)
        {
            Response.StatusCode = 500;
            Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
        }
    }
</script>
