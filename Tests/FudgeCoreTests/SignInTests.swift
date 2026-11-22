import Foundation
import Testing

@testable import FudgeCore

// SPEC-056: sign-in through a fudge-oauth relay. The provider table, the settings rules, the callback parser and the
// token store, with a fake Keychain.

// MARK: - The provider table

@Test func everyBuiltInProvidersDefaultURLsMapAndNothingElseDoes() {
    #expect(
        OAuthProviders.all.map(\.id) == [
            "github", "github", "linear", "slack", "asana", "google", "atlassian", "atlassian", "zoom", "zoom",
            "notion",
            "notion", "todoist", "basecamp", "gumroad", "moneybird", "freeagent", "mollie", "plane", "homey", "figma",
            "intra42", "ticktick", "zoho", "webflow",
        ])
    for provider in OAuthProviders.all {
        #expect(OAuthProviders.provider(authorizing: provider.authorizeURL) == provider, "\(provider.id)")
    }
    // @raycast/utils 2.3.3's defaults.
    #expect(OAuthProviders.provider(authorizing: "https://github.oauth.raycast.com/authorize")?.id == "github")
    #expect(OAuthProviders.provider(authorizing: "https://accounts.google.com/o/oauth2/v2/auth")?.id == "google")
    #expect(OAuthProviders.provider(authorizing: "https://auth.atlassian.com/authorize")?.id == "atlassian")
    #expect(OAuthProviders.provider(authorizing: "https://zoom.us/oauth/authorize")?.id == "zoom")
    for other in [
        "https://github.com/login/oauth/authorize", "https://github.oauth.raycast.com/authorize/",
        "https://github.oauth.raycast.com/token", "http://github.oauth.raycast.com/authorize",
        "https://GITHUB.oauth.raycast.com/authorize?x=1", "https://example.com/authorize", "",
    ] {
        #expect(OAuthProviders.provider(authorizing: other) == nil, "\(other)")
    }
    #expect(
        OAuthProviders.raycastHosts.sorted() == [
            "asana.oauth.raycast.com", "github.oauth.raycast.com", "jira.oauth.raycast.com",
            "linear.oauth.raycast.com", "notion.oauth.raycast.com", "slack.oauth.raycast.com", "zoom.oauth.raycast.com",
        ])
    let google = OAuthProviders.all.first { $0.id == "google" }!
    #expect(google.refreshURL == google.tokenURL, "Google refreshes at its token URL")
    let github = OAuthProviders.all.first { $0.id == "github" }!
    #expect(github.refreshURL == "https://github.oauth.raycast.com/refresh-token")
}

/// The store's Jira and Zoom extensions sign in through Raycast's own proxies (FUD-137). Those exact URLs go to the
/// relay's Atlassian and Zoom providers, beside the providers' own URLs, which `OAuthService` uses by default.
@Test func raycastsJiraAndZoomProxiesGoToTheRelay() throws {
    let jira = try #require(OAuthProviders.provider(authorizing: "https://jira.oauth.raycast.com/authorize"))
    #expect(jira.id == "atlassian" && jira.name == "Atlassian (Jira, Confluence)")
    #expect(jira.tokenURL == "https://jira.oauth.raycast.com/token")
    #expect(jira.refreshURL == "https://jira.oauth.raycast.com/refresh-token")
    let zoom = try #require(OAuthProviders.provider(authorizing: "https://zoom.oauth.raycast.com/authorize"))
    #expect(zoom.id == "zoom")
    #expect(zoom.refreshURL == "https://zoom.oauth.raycast.com/refresh-token")
    // Both Atlassian entries reach the relay's one provider.
    let server = SignInServer.custom(URL(string: "https://relay.example")!)
    let atlassian = try #require(OAuthProviders.provider(authorizing: "https://auth.atlassian.com/authorize"))
    #expect(server.endpoint(jira, "authorize") == "https://relay.example/atlassian/authorize")
    #expect(server.endpoint(atlassian, "authorize") == "https://relay.example/atlassian/authorize")
    // Only those exact URLs: no lookalike host, scheme, path or query.
    for lookalike in [
        "https://jira.oauth.raycast.com.evil.test/authorize", "http://jira.oauth.raycast.com/authorize",
        "https://jira.oauth.raycast.com/authorize/x", "https://zoom.oauth.raycast.com.evil.test/authorize",
        "http://zoom.oauth.raycast.com/authorize", "https://zoom.oauth.raycast.com/authorize?x=1",
    ] {
        #expect(OAuthProviders.provider(authorizing: lookalike) == nil, "\(lookalike)")
    }
    // Each URL belongs to one entry, so a request is never sent for the wrong one.
    let urls = OAuthProviders.all.flatMap { provider in
        [provider.authorizeURL, provider.tokenURL]
            + (provider.refreshURL == provider.tokenURL ? [] : [provider.refreshURL])
    }
    #expect(Set(urls).count == urls.count)
}

/// Seven more of Raycast's sign-in addresses that store extensions use (FUD-166, batch 1): Notion's and Todoist's
/// proxies, and five extensions' own apps on Raycast's shared proxy, each copied from the extension at `ce8f05c`.
@Test func theStoresOtherRaycastSignInAddressesGoToTheRelay() throws {
    let entries: [(id: String, name: String, authorize: String, token: String, refresh: String)] = [
        // The store's Notion extension, through Raycast's Notion proxy.
        (
            "notion", "Notion", "https://notion.oauth.raycast.com/authorize", "https://notion.oauth.raycast.com/token",
            "https://notion.oauth.raycast.com/refresh-token"
        ),
        // The store's Todoist extension, through Raycast's Todoist proxy; it refreshes at its token URL.
        (
            "todoist", "Todoist", "https://todoist.oauth-proxy.raycast.com/authorize",
            "https://todoist.oauth-proxy.raycast.com/token", "https://todoist.oauth-proxy.raycast.com/token"
        ),
        // `github-copilot`, its author's app on Raycast's shared proxy.
        (
            "github", "GitHub",
            "https://oauth.raycast.com/v1/authorize/ZJFTemDOnon9VgfOxbFostk2HJqDaHtXFizUhliOj5WNPEcL3n9Mjzf_NWXwTDo5UHmMpzAaX0hOk5GZggt_Gkq7J3VlakVu7C67POdoLtId--l3BOI9j-rxsyrYqdo4iFocQmEFYpNGY97ulVc",
            "https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc",
            "https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc"
        ),
        // `raycast-pomodoro-notion`, its author's app on Raycast's shared proxy.
        (
            "notion", "Notion",
            "https://oauth.raycast.com/v1/authorize/c7Qokr0CiZIEHW7WoevaKukgEOtjEFGI1lYt3_kYC6k8CNeqRO8xF9BtpZUePirKQM2KwJH21RCJI1I2I4VeutakujJ2EZJQoypCI_Cg4OOaRCqT4a5MLxiYcBHGDXsp52ewVVrzzGM5KjfY951bomaB3ELg6qoLeQ",
            "https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-",
            "https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-"
        ),
        // `trek`, its author's app on Raycast's shared proxy.
        (
            "basecamp", "Basecamp",
            "https://oauth.raycast.com/v1/authorize/Yu5bylqUnHj-jHAkK4iRGFKxrV_ObMQz4TEPVf4zHD3UxkB9A2WIdhPF18B4B76kimV7t1ks7MZQE2wqKh6Zc9MVsxKqVB2CLZvhZfnkTBzRu1YXFn9EXbPJz0602roPZLt6p_x-PWbvi5OG8JIaZFkyiqbnkVE",
            "https://oauth.raycast.com/v1/token/wMaXr3BdE5QWGZQ_RE_7GyB37_wTuBYOg_9C7CxiqtwHYOELsCyxDKiOshV4mPWXj9NZ_cZ9-dLIkELMnqbN08GDHCnmBp0i2Z950v2kWuOU88VMf3YxkiQAxj5HiAGYW9ceuj9hTDeIBYyBIXciFpDsR6WPhJAjJsHqvz2j8IQQe28efSJFi18",
            "https://oauth.raycast.com/v1/refresh-token/zUVueWjJBw5e_3E04mUmut6L1LiT8fa6FdubGOtITFX_Gx3nilkwNIUISui62gZbvu6yXqDWHy7UKdM9R5RXPUQu-9q-zEsgnK2NhTktNwp2wmGT60Rg-mXFUUd_jg4fwBzIXj5cOBculalOYYodpTWi8bJJBp60XCxA_0C4hctAhKftD8soF-A"
        ),
        // `gumroad`, its author's app on Raycast's shared proxy.
        (
            "gumroad", "Gumroad",
            "https://oauth.raycast.com/v1/authorize/6u4QNlwsUEvYJiwlmx-jGSBLpe0QloUowsc9PMy64xyP31e0kMWtiJCyTz4b_9EPuycLxrAIvZfFtVczX9fPJfU5Xt5h2ib3aZRDa85rRqQbFe1hqyVXIQdIPXo2mZdkSp9N7P2pFtAeykI3",
            "https://oauth.raycast.com/v1/token/cAfVd74pOuU0WIWMymDxtIHXg2c1Hai7gBXmE4DZGFk4tRZczsTQlJzrFzbwSYE3TmlIEse4FP4uUy9EYX35zYfsI0_2mfKmLudJ4wsC-8zUsEXhJwnIn11TJmNeH2bpiWxqQpU-K4Q",
            "https://oauth.raycast.com/v1/refresh-token/-8K39Rwy5HY5-DzNTOVLTMvKH6EQVd5E50z9mvLJ4bahXJu2susPq_DcGFFUYrhctLgTTXZLhmYRvlBnpIaGuxPDB7QTscbBrsz63tOA4RvPXoqJYh4JKtyUgQMAheFWBKh6gvNI08Q"
        ),
        // `moneybird`, its author's app on Raycast's shared proxy.
        (
            "moneybird", "Moneybird",
            "https://oauth.raycast.com/v1/authorize/2QijvWZlCgJtKVzE9EG_mGx2DulRYvJQZlKC0cN8CwjSTccDV-mwsxiRx03lbj63Hl53CKRb5vi37PJ8AJMvarHholI5CvrGbIX7AeIIyoqcX-bAF2bnwnKGWzK-7EWxqJxog9aX4KD1lS_CyVONoOBVhhCIsTUpzeuusGMuDfD-H90",
            "https://oauth.raycast.com/v1/token/HkdQIb7W7JlFwNFCj2yL6zDPvJHb-vnTCrL_iPlT_K77Z-hQHyRJ-iiLSrkfjNta8Yys7_qRGKHBiAIVVt5GnqiV-VvvegeT9INJ24TrXTHk_P2MT0GOTd8fD9ogDuOgdPyMahi1mePSjhGKHTsBuPloYZFqNnDSzr4_ioxJBQ",
            "https://oauth.raycast.com/v1/refresh-token/66Tt7sCc6O70T4V3Rf_Dr4B941f08fkyizdDhimTODW0M7niNRllwvyk7FLX3XLaj0WNAWZBeOG1fZ8E1aTYWQR8ThljnyaUy3zS68Ocd5oxI6p4SUY7q2oIs_IauacmW75epq8Mn-mrdcpnmpuL19R7iPHgFy3FBS1ZeHRbSg"
        ),
        // `freeagent`, its author's app on Raycast's shared proxy.
        (
            "freeagent", "FreeAgent",
            "https://oauth.raycast.com/v1/authorize/PLlKWDuFWQjTTgdJHUy-wK47_zN8lc2ATzyvHJSoNy5WazXXYTG_h8Yz1eOPwlUvB-YNQos46o_9lgTxwUdQN3L9P4LsjYwgitMYkEmcHtGHsUyZYyBXwng3lgE",
            "https://oauth.raycast.com/v1/token/csqaHeGaTfTpistIum6eBy7DDrJjcz7Z-FmW_HuU4Dsa3r-AhgMCGcEWYUCLR3k-5-PirrX1ilceu4WfRqUQlyCSEiYqzkZkIIKyx5n7khRbIe99FHiEBtENFXUZRz8",
            "https://oauth.raycast.com/v1/refresh-token/wg1eYlPV441y6BfHcmZi19x61W2tqw045Dup4C6M8VgERbxtFByj1J97OeYVaiPHbYWoLz3nNnZ3nzXoMnZbqP6EhVYkT8eJefM79ey5sQLcdRL9vGnlBsLMqaB_Ylg"
        ),
        // `mollie-for-raycast`, its author's app on Raycast's shared proxy.
        (
            "mollie", "Mollie",
            "https://oauth.raycast.com/v1/authorize/NxaZKqcp7vp8pAw3Mp8r8UOXy_z3pnka8zfft5NcBEoB09N36m-7Y6r_EBUphunBEkTTec8UnAC_hq1ENW73rgp77by3LF_mXqJ4ct1g9kqbLRe8Hx1ezlHoU2sxnqKZfzHWkdV7hGugdqZksA",
            "https://oauth.raycast.com/v1/token/5p7_7xQdzkXilZdhppv_or2B9wwd0Sm7Fx0khb74h_MHnro7AO5w4tr9-aj5vJe4C0NnlLsV1Onr24ndgmFR5J_yRpV6b_hD8BzYSg6lcH1Q7s-1DUfZ0JFlZjE2nF0j-vunQ34iLi8d8w",
            "https://oauth.raycast.com/v1/refresh-token/hiXK17eErlQSoxjH5w0qTI3fjCmQt-Qw7TWqV0PhNEi6xvSqLjnklSkwNy7D0g67FwQAfXV3udahWqjl2tFPa5b7zO_rFNtJQTvPto9gQMrQDdQFFC6VvdGZstEn8K2juivJh2SwmBzBfg"
        ),
        // `plane`, its author's app on Raycast's shared proxy.
        (
            "plane", "Plane",
            "https://oauth.raycast.com/v1/authorize/dAAojlwLRis2jBTlrt8vrrmmaMYGJO0ZuPZb8awD6ouUaNVltt_bEeZACr4zFPcHvV0U5IVaAabS3IWAn0R-JN1vvk1g5WqXSrYpyH9SQAXQ2-nquGy9KhyrfKd8JnnBFC0kMLzniS13BIrr0F9mbrSMZuhXITeAlgHSnlJcqHBw7MMYbLNfwbMbeHPofwDPbroIsU1l8VVPQpu3Xba8L0jy6rBAQeczGhi0ghcoEfeuogNd5r3CRyU9WgCGoB3e7VqNvWNk5e0",
            "https://oauth.raycast.com/v1/token/9KXLatvC9QrbuSafABDqcnA8IZW-JXwd4FF4CvZ-C6LFXfbl8FONXyjGuaO1n2XEFIW6bvDFFWDKH5IB_9gupDVVPiAHt5_mNmQJTQ_OmF7AYcKe6fF3I13O_hYIOETpCPknFn9ww9arA93J2knoGIWRSE-FFoVB2_lBGL8xP8FaRaj8_S6M-fsKUOg1YyyOFaK6dIIN5LF8i6P5J8y_L8Q6hWu4ZyyxmLCKHmEyPY9uoK-6ZZ27W0LMIrNzSHTS",
            "https://oauth.raycast.com/v1/refresh-token/dERRhlRqcHTtXPJLaZZqs7h8JYsRPZrQeWpVvNN_5F9qd_Z6Hb1q6xr_iVeLUmKBj9Ewk3xHAuADSKCpQ1fb0rJq07vziFLkate0VW2zkV0a-xfj23KBoVM2y50aA4geUo7XQT4PS0MKFBIt44ZaD0QRnr3gdZIf37xWollM66pK35YAmuIgo4uFDFJnj1-A1zJ8FvuYL16tHK5qO4nK6SBKE-AktYpraqpziJUINAwN6ByKe_JO1MdvtGGeMb-5"
        ),
        // `homey`, its author's app on Raycast's shared proxy.
        (
            "homey", "Homey",
            "https://oauth.raycast.com/v1/authorize/WTWZbnJLBrEo1FEYJ0E4Ix5Wpsxnpfkcb5d2EURGgmOtgPnpIE8QvYHgJX0LeG9yryHZ71LssD1tli8bdKKVlKuEIMx-W-Ql8H72V2kBFkRgv0HPkPPGPv6ULdVrop4rZsMi-kohkLrs7glA",
            "https://oauth.raycast.com/v1/token/7EXpLgXJ1PDijhpr-BiJe3CVd8JGSZsST-oAdflCaTWLJuEE0vRMulR8bHGX4SRrBJWgXgZKC4A0b2jF90p7QELwCoXdZQnHrigsXbfLOolG1PwDUbDNB971f6EllEs4ndcak66nGw8",
            "https://oauth.raycast.com/v1/refresh-token/ptpJtGSqQUGUt9zDDZGzv4iW-Vn7965_rjjtPM3sOeRSXhXL_GIF4ZrNDUR21AhW5zg-MUeZuMdoKG1co7oEkas3HYBat5-W4rLPUMScN0yOM5zlapM6xD-ryNobzZ55v22lc_5qXKo"
        ),
        // `figma-files`, its author's app on Raycast's shared proxy.
        (
            "figma", "Figma",
            "https://oauth.raycast.com/v1/authorize/F7SnNEtLc3w2AFfhwdtXwpE-rW2l2OOtG3h0z76VKM6YJVtkU17gAmgJgqzIn6lO3X9SCv_iv3_3BS8a1Jq0gc14HUxILPg8wQNB8zBaX4-OjUj2ixG0",
            "https://oauth.raycast.com/v1/token/rsuQtsavqnjuxmA3vCYSGa3E-D8_ruhzY4OqJIOA7aB4_wGaFh2WE0mQc_uMZ7E5Nk8-pAeW3JXE3WlUfgqu_-zNiM4yWU7i_z2-u0pO8HJFh7_H6ohVBh8fcDpk64nT",
            "https://oauth.raycast.com/v1/refresh-token/qJfyXOqhjDouaj06_54vl2O3NoIfY36R_-OOExXZNAS073Bih0aeNaHLO9xEpW6lbooqWCpT6zO7zLvbTx1MtXF2dU5d4B_of5d05Yxh27JIAPHG0uBw7fINhej_ViQ-sbE"
        ),
        // `42-api`, its author's app on Raycast's shared proxy.
        (
            "intra42", "42",
            "https://oauth.raycast.com/v1/authorize/MnlQFVxIGQ4k6vhqj0q7FUyjXQs7FbP504oq2kWvU0DQ7ydArhDDZo_0RZLytPp3cBI4XAAi6JhEM4dq3POHTarPLiM-OJScM_6D1S3WCTynD_ArEsOIIihJC7KQvZL3X5vaDaKBygzemteTqVfTT3mxFpHXRwDMaMwKrSBimszqxqSJre9Cm_rkaA4ovOKh9A",
            "https://oauth.raycast.com/v1/token/CQ8Acmd1GJ7WXGwXJ0BdBOtMhyiGcdZMPpq7pnM74LNkLiB6gRMSJ33oMtJ0bGkKFlG3IitUPqnW89BL8_VQ6t6Vex1Znps-pAd0itvAr1q0VaawTwfopc43vp-soOvKY9A1U8dfeKGOh9iDyGWrN-_NsDEO-UcJTazwwIBaPo1hRX4kdlHWRueDTrXS",
            "https://oauth.raycast.com/v1/refresh-token/3M-j9Q4RZaZelFapmWrXeGPyaVV2zce7OIBsa7_8yMZ-Z-wH0UnsPVvGlNwo3n8IBZs-dEyVDLVusP6hjYD4seIut6Jv24LtdvogyEDNcuRpOmyb6DEX-hnvnT56MH47XJ-aNiCWAJC4SIn3WeMA7T-wdlbsuxWvHA1Aw7IyA5jNLwTyALavTOnrY69W"
        ),
        // `ticktick-plus`, its author's app on Raycast's shared proxy.
        (
            "ticktick", "TickTick",
            "https://oauth.raycast.com/v1/authorize/mgIpKnxTo3jdnE1IUETN_zw4tSRTSnH6DffToE_gh1deVyanGQ53X1ZN8QrZtl8XgYkARnurl9iQVFtuOvNYPMmaEtZoY05ZV7KmAF4GE2NNmlJScX8Hd3_RRm054E_hRus",
            "https://oauth.raycast.com/v1/token/SXhT3SrBQS_UHzaHXdkI28IHvtPy1y79lN5b7WoFnWn6gbvztRZkAL906CUce9e4DbOLgWxhVLCG_Bxi0Ur3d4H7bBprZDsofulVmBBdNJgrF1mH-b2iJRDck9uLWA",
            "https://oauth.raycast.com/v1/refresh-token/sZgB0AoTB26kqAhJ7pKwC-c0Csk7iMGAQ3OwBADMcZd0ntppCz-q3tTb4VRgutPDL-JiXn4JbkrkCggRXIlO5mQp7VJvLO7XuPxJ2oqLO7dJPEziEKzsKHEeMRgfGw"
        ),
        // `zoho-mail`, its author's app on Raycast's shared proxy.
        (
            "zoho", "Zoho",
            "https://oauth.raycast.com/v1/authorize/L56YnDJ7Pyv-SZlWPCgVlUHSVMI4Eo71Yzox2S9xDRtI83vegut87tcNRpoby4W-_L3m6rYKozB71tAb1THv3G00VX-9rvnQ5klOYengXzr7E8GE6pEIFP9rCqF2KCHqAV_yVzzjYYgt7ztx3FS1",
            "https://oauth.raycast.com/v1/token/IzJ2IgubKiVDyntspLduHwp2fbqLnidriix9jaZCAzZbj2wdsPWfJpv3TUtpQCRyopHNO1YPx0HgWOiQlaIaDiJu8zCrnvxFsp9beqRPVE1w5acImQsJ3BHoVq36OD3mAS6BV0FlkgzkPWjcqjMvzg",
            "https://oauth.raycast.com/v1/refresh-token/PkgYXNFbQinA8SK-3Wvcl8xdP7Hq-kaX6ur_sct3_qk_ATrFgb8uneFkkpkwlACWOjsnG_TIvW75N7SdQ9Afd-ZfeKxtqdHj2yYEfg5Y0oueBi8zBwGoRWc-sglHUgecZaF2PQfuzqKZ0JoXL2JP4w"
        ),
        // `webflow-sites`, its author's app on Raycast's shared proxy.
        (
            "webflow", "Webflow",
            "https://oauth.raycast.com/v1/authorize/SpqHimJblCsEsHMaOX6bSCGCatuNIU9D8vHt3qn0eGhM9Dhqs-K2TDWF2KFer-G-LizUGpxKDwkTBA-oGVs9yAJzI-GsWPkS3UTCbil0P5rY5VxHVic2kuBzEaQan7HBhfvFHLwOYnbd69mx0blWKqXxgWW7sZ3FqagkphxttM0n",
            "https://oauth.raycast.com/v1/token/q4QKZun0V_mQeHqwiKbrv-G8fdDGM1-an2xu3vMO5AqrmUHnzIC4pjEpHf_I2XWtpR3uMK42EtKQiqNljaEE3rtacJnOHrip0_2B4K7Ci3WClmnjzv9gwmyYtmaGl4qIeU10j2RTDWVRq_jeUwc5Ze2_RCwYWdikkqKsfiLkJWZVahPvI0-RaA",
            "https://oauth.raycast.com/v1/refresh-token/OUvaPcCuUx4pAsmO9NlL0SjzRIsj1iquQtVbDxZlJHw5AxRqpEykQrSAKVa13YZNyTulfh8hUtGnOsmNEdMCyvflcIegE6MhbCr5BYS9Zdznb95mcJiXhduhwmXr9OXV6srwF4DmOUEnVwMzH7Pv8i8KmFxRRjbmm9rku70X_yNeVIxu9bzKzg"
        ),
    ]
    let server = SignInServer.custom(URL(string: "https://relay.example")!)
    for entry in entries {
        let found = try #require(OAuthProviders.provider(authorizing: entry.authorize), "\(entry.authorize)")
        #expect(found.id == entry.id && found.name == entry.name, "\(entry.authorize)")
        #expect(found.tokenURL == entry.token && found.refreshURL == entry.refresh, "\(entry.authorize)")
        #expect(server.endpoint(found, "authorize") == "https://relay.example/\(entry.id)/authorize")
    }
    // Only those exact URLs.
    let shared =
        "https://oauth.raycast.com/v1/authorize/Yu5bylqUnHj-jHAkK4iRGFKxrV_ObMQz4TEPVf4zHD3UxkB9A2WIdhPF18B4B76kimV7t1ks7MZQE2wqKh6Zc9MVsxKqVB2CLZvhZfnkTBzRu1YXFn9EXbPJz0602roPZLt6p_x-PWbvi5OG8JIaZFkyiqbnkVE"
    var changed = Array(shared)
    changed[changed.count - 1] = changed.last == "A" ? "B" : "A"
    for lookalike in [
        shared + "/", String(changed), shared + "?x=1", "http" + shared.dropFirst("https".count),
        "https://oauth.raycast.com/v1/authorize/unknown", "https://todoist.oauth-proxy.raycast.com.evil.test/authorize",
        "http://todoist.oauth-proxy.raycast.com/authorize",
    ] {
        #expect(OAuthProviders.provider(authorizing: lookalike) == nil, "\(lookalike)")
    }
    // The same for one of batch 2's addresses (`figma-files`).
    let figma =
        "https://oauth.raycast.com/v1/authorize/F7SnNEtLc3w2AFfhwdtXwpE-rW2l2OOtG3h0z76VKM6YJVtkU17gAmgJgqzIn6lO3X9SCv_iv3_3BS8a1Jq0gc14HUxILPg8wQNB8zBaX4-OjUj2ixG0"
    var figmaChanged = Array(figma)
    figmaChanged[figmaChanged.count - 1] = figmaChanged.last == "A" ? "B" : "A"
    for lookalike in [figma + "/", String(figmaChanged), figma + "?x=1", "http" + figma.dropFirst("https".count)] {
        #expect(OAuthProviders.provider(authorizing: lookalike) == nil, "\(lookalike)")
    }
    // And for one of batch 3's (`zoho-mail`).
    let zoho =
        "https://oauth.raycast.com/v1/authorize/L56YnDJ7Pyv-SZlWPCgVlUHSVMI4Eo71Yzox2S9xDRtI83vegut87tcNRpoby4W-_L3m6rYKozB71tAb1THv3G00VX-9rvnQ5klOYengXzr7E8GE6pEIFP9rCqF2KCHqAV_yVzzjYYgt7ztx3FS1"
    var zohoChanged = Array(zoho)
    zohoChanged[zohoChanged.count - 1] = zohoChanged.last == "A" ? "B" : "A"
    for lookalike in [zoho + "/", String(zohoChanged), zoho + "?x=1", "http" + zoho.dropFirst("https".count)] {
        #expect(OAuthProviders.provider(authorizing: lookalike) == nil, "\(lookalike)")
    }
}

/// A sign-in the relay's Atlassian provider made while it was still called "jira" counts as Atlassian's.
@Test func aSignInMarkedWithTheOldJiraNameCountsAsAtlassians() throws {
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    var old = StoredTokenSet(accessToken: "a", updatedAt: "2026-11-21T12:00:00Z")
    old.relayProvider = "jira"
    try store.save(old, extension: "jira", provider: "jira")
    let calls = SignInCalls(store: store, extensionName: "jira", pending: [])
    #expect(try calls.hasRelaySignIn(provider: "atlassian"))
    #expect(try !calls.hasRelaySignIn(provider: "zoom"))
    #expect(OAuthProviders.currentRelayProvider("jira") == "atlassian")
    #expect(OAuthProviders.currentRelayProvider("zoom") == "zoom")
}

/// The runtime's tests load the same table from this file, so the two can't drift apart.
@Test func theTableTheHostGetsMatchesTheRuntimesFixture() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/oauth-providers.json")
    let pinned = try JSONDecoder().decode([OAuthProvider].self, from: Data(contentsOf: fixture))
    #expect(pinned == OAuthProviders.all)
    let sent = try JSONDecoder().decode([OAuthProvider].self, from: Data(OAuthProviders.environmentValue.utf8))
    #expect(sent == OAuthProviders.all)
    #expect(OAuthProviders.environmentKey == "FUDGE_OAUTH_PROVIDERS")
}

// MARK: - The setting

@Test func aServerCountsOnlyWithItsConsent() throws {
    var settings = FudgeSettings()
    #expect(settings.signIn == .off)
    settings.signInServer = "fudge"
    #expect(settings.signIn == .off, "a hand-set value without the consent time counts as off")
    settings.signInServerConsentAt = "not a date"
    #expect(settings.signIn == .off)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    settings.setSignIn(.fudge, now: now)
    #expect(settings.signIn == .fudge)
    #expect(settings.signInServer == "fudge")
    #expect(settings.signInServerConsentAt == ISO8601DateFormatter().string(from: now))
    #expect(settings.signIn.url == SignInServer.fudgeURL)
    #expect(SignInServer.fudgeURL.absoluteString == "https://fudge-oauth.rackofpain.net")

    let own = URL(string: "https://sign-in.example.com")!
    settings.setSignIn(.custom(own), now: now)
    #expect(settings.signIn == .custom(own))
    #expect(settings.signInServer == "https://sign-in.example.com")

    settings.setSignIn(.off, now: now)
    #expect(settings.signInServer == nil && settings.signInServerConsentAt == nil, "off removes both")

    // A saved value that isn't a valid server is off, consent or not.
    settings.signInServer = "http://example.com"
    settings.signInServerConsentAt = ISO8601DateFormatter().string(from: now)
    #expect(settings.signIn == .off)
}

@Test func theSignInKeysRoundTripThroughSettingsJSON() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    settings.setSignIn(.custom(URL(string: "http://localhost:8080")!), now: Date())
    try settings.save(to: file)
    let loaded = FudgeSettings.load(from: file)
    #expect(loaded.signIn == .custom(URL(string: "http://localhost:8080")!))
    var off = loaded
    off.setSignIn(.off, now: Date())
    try off.save(to: file)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    #expect(object["signInServer"] == nil && object["signInServerConsentAt"] == nil)
}

@Test func ownServerAddressesAreCheckedBeforeTheyreSaved() {
    func problem(_ text: String) -> SignInServer.Problem? {
        if case .failure(let problem) = SignInServer.validate(text) { problem } else { nil }
    }
    #expect(
        SignInServer.validate("https://sign-in.example.com") == .success(URL(string: "https://sign-in.example.com")!))
    #expect(
        SignInServer.validate("  https://corp.example/oauth/ ") == .success(URL(string: "https://corp.example/oauth/")!)
    )
    #expect(SignInServer.validate("http://localhost:8080") == .success(URL(string: "http://localhost:8080")!))
    #expect(SignInServer.validate("http://127.0.0.1:9000") == .success(URL(string: "http://127.0.0.1:9000")!))
    #expect(problem("") == .empty)
    #expect(problem("   ") == .empty)
    #expect(problem("sign-in.example.com") == .notAURL)
    #expect(problem("ftp://example.com") == .notAURL)
    #expect(problem("https://") == .notAURL)
    #expect(problem("http://example.com") == .insecure)
    #expect(problem("http://localhost.example.com") == .insecure)
    #expect(problem("http://192.168.1.2") == .insecure)
    #expect(problem("https://user:pass@example.com") == .extraParts)
    #expect(problem("https://example.com/?a=1") == .extraParts)
    #expect(problem("https://example.com/#x") == .extraParts)
    #expect(SignInServer.Problem.insecure.message == "Use https://, or http:// on localhost or 127.0.0.1.")

    // Saved as the worker's `new URL()` writes it (each expected value is Node's `href`, without the "/" it adds to
    // an empty path), so a sign-in's authorize URL comes back unchanged.
    let normalised = [
        ("https://Relay.Example", "https://relay.example"),
        ("HTTPS://relay.example", "https://relay.example"),
        ("https://relay.example:443", "https://relay.example"),
        ("https://relay.example:0443/x", "https://relay.example/x"),
        ("http://LOCALHOST:8080", "http://localhost:8080"),
        ("http://localhost:80", "http://localhost"),
        ("https://relay.example:8443", "https://relay.example:8443"),
        ("https://relay.example/a/../b", "https://relay.example/b"),
        ("https://relay.example/a/./b/%2e%2E/c", "https://relay.example/a/c"),
        ("https://relay.example/a/..", "https://relay.example/"),
        ("https://relay.example/.", "https://relay.example/"),
        ("https://Relay.Example/Base/", "https://relay.example/Base/"),
        ("https://10.0.0.1", "https://10.0.0.1"),
        ("https://relay.example./x", "https://relay.example./x"),
    ]
    for (typed, saved) in normalised {
        #expect(SignInServer.validate(typed) == .success(URL(string: saved)!), "\(typed)")
    }
    // Hosts that parser rewrites in other ways aren't accepted: IPv4 in other notations, percent-encoded or
    // non-ASCII names, IPv6. A port past 65535 isn't a URL there.
    for typed in [
        "https://0x7f.0.0.1", "https://127.1", "https://010.0.0.1", "https://10.0.0.1.", "https://re%6Cay.example",
        "https://relä.example", "https://[::1]", "https://relay.example:99999",
    ] {
        #expect(problem(typed) == .notAURL, "\(typed)")
    }

    // End to end: the authorize URL the worker sends back, as Node writes it, is the prepared request's.
    let redirect = "http://127.0.0.1:5000/oauth/callback/abc"
    let query = "?redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Foauth%2Fcallback%2Fabc&state=s1"
    for (typed, fromNode) in [
        ("https://Relay.Example", "https://relay.example/github/authorize"),
        ("https://relay.example:443/a/../b/", "https://relay.example/b/github/authorize"),
        ("http://LOCALHOST:80", "http://localhost/github/authorize"),
    ] {
        guard case .success(let url) = SignInServer.validate(typed),
            case .success(let (provider, authorize)) = PreparedSignIn.provider(
                for: "https://github.oauth.raycast.com/authorize", providerName: "GitHub", server: .custom(url))
        else {
            Issue.record("\(typed) wasn't accepted")
            continue
        }
        let request = PreparedSignIn(provider: provider, authorizeURL: authorize, redirectURI: redirect)
        #expect(request.state(ofAuthorizeURL: fromNode + query) == "s1", "\(typed)")
    }
}

@Test func theRelaysEndpointsAreUnderTheServersAddress() {
    let github = OAuthProviders.all[0]
    #expect(SignInServer.fudge.endpoint(github, "authorize") == "https://fudge-oauth.rackofpain.net/github/authorize")
    let own = SignInServer.custom(URL(string: "https://corp.example/oauth/")!)
    #expect(own.endpoint(github, "token") == "https://corp.example/oauth/github/token")
    #expect(SignInServer.off.endpoint(github, "token") == nil)
    #expect(own.host == "corp.example")
    #expect(SignInServer.Consent.title(host: "corp.example") == "Extensions will sign in through corp.example.")
}

// MARK: - Preparing a sign-in

@Test func preparingRefusesWhileOffAndForProvidersFudgeDoesntKnow() {
    let github = "https://github.oauth.raycast.com/authorize"
    #expect(PreparedSignIn.provider(for: github, providerName: "GitHub", server: .off).failure == .off)
    #expect(
        SignInRefusal.off.message
            == "Sign-in is off. This extension needs to sign in with OAuth to work. Turn on sign-in in Fudge's settings, "
            + "or, if it takes a token, set it in its settings."
    )
    let unknown = PreparedSignIn.provider(for: "https://example.com/oauth", providerName: "Example", server: .fudge)
    #expect(unknown.failure == .unknownProvider("Example"))
    #expect(SignInRefusal.unknownProvider("Example").message == "Fudge can't sign in to Example yet.")
    let prepared = PreparedSignIn.provider(for: github, providerName: "GitHub", server: .fudge)
    #expect(prepared.value?.0.id == "github")
    #expect(prepared.value?.1 == "https://fudge-oauth.rackofpain.net/github/authorize")
}

@Test func onlyTheRequestsOwnAuthorizeURLMayBeOpened() {
    let request = PreparedSignIn(
        provider: OAuthProviders.all[0], authorizeURL: "https://relay.example/github/authorize",
        redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
    let redirect = "redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Foauth%2Fcallback%2Fabc"
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(redirect)&state=s1") == "s1")
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(redirect)") == nil, "no state")
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?state=s1") == nil, "no redirect")
    #expect(request.state(ofAuthorizeURL: "https://evil.example/github/authorize?\(redirect)&state=s1") == nil)
    #expect(request.state(ofAuthorizeURL: "https://relay.example/slack/authorize?\(redirect)&state=s1") == nil)
    #expect(request.state(ofAuthorizeURL: "http://relay.example/github/authorize?\(redirect)&state=s1") == nil)
    let other = "redirect_uri=http%3A%2F%2F127.0.0.1%3A5001%2Foauth%2Fcallback%2Fabc"
    #expect(request.state(ofAuthorizeURL: "https://relay.example/github/authorize?\(other)&state=s1") == nil)
}

// MARK: - Which listener a sign-in uses

private final class Listener {}

@Test func thePromptKeepsTheListenerItWaitsOnWhateverTheSessionPreparesMeanwhile() {
    func request(_ listener: Listener) -> SignInRequests<Listener>.Request {
        let prepared = PreparedSignIn(
            provider: OAuthProviders.all[0], authorizeURL: "https://relay.example/github/authorize",
            redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
        return (prepared, listener)
    }
    var requests = SignInRequests<Listener>()
    let first = Listener()
    let second = Listener()
    let third = Listener()

    // An unused request is replaced, and its listener closed.
    let none = requests.prepare(request(first), for: "s1")
    let replaced = requests.prepare(request(second), for: "s1")
    #expect(none == nil && replaced === first)
    #expect(requests.preparedRequest(of: "s1")?.listener === second)

    // The prompt takes the request. Preparing again meanwhile closes nothing, and Esc still reaches the prompt's.
    let shown = requests.show("s1")
    let again = requests.show("s1")
    #expect(shown?.listener === second)
    #expect(again == nil, "one prompt at a time")
    #expect(requests.preparedRequest(of: "s1") == nil)
    let closed = requests.prepare(request(third), for: "s1")
    #expect(closed == nil, "the prompt's listener isn't closed")
    #expect(requests.waitedOn === second)
    let expired = requests.expire(second, of: "s1")
    #expect(!expired, "a shown request never expires")

    // Another session going away leaves the prompt alone; its own going away cancels the prompt's listener and
    // closes the unused one, and the prompt goes when its sign-in finishes.
    let other = requests.end("s2")
    #expect(other.unused == nil && other.waitedOn == nil)
    let ended = requests.end("s1")
    #expect(ended.unused === third && ended.waitedOn === second)
    #expect(requests.waitedOn === second, "the prompt stays until its sign-in finishes")
    let finishedOther = requests.finish(third, signedIn: false)
    let finished = requests.finish(second, signedIn: false)
    #expect(!finishedOther && finished)
    #expect(requests.shown == nil && requests.waitedOn == nil)

    // An unused request expires only while it's still the session's latest.
    _ = requests.prepare(request(first), for: "s1")
    _ = requests.prepare(request(second), for: "s1")
    let stale = requests.expire(first, of: "s1")
    let latest = requests.expire(second, of: "s1")
    let left = requests.show("s1")
    #expect(!stale && latest)
    #expect(left == nil, "nothing left to show")
}

@Test func aRelaySignInIsPendingOnlyUntilItEndsWithoutACode() {
    func request(_ provider: Int, _ listener: Listener) -> SignInRequests<Listener>.Request {
        let prepared = PreparedSignIn(
            provider: OAuthProviders.all[provider], authorizeURL: "https://relay.example/x/authorize",
            redirectURI: "http://127.0.0.1:5000/oauth/callback/abc")
        return (prepared, listener)
    }
    let github = OAuthProviders.all[0].id
    let linear = OAuthProviders.all[1].id
    var requests = SignInRequests<Listener>()
    let first = Listener()
    let second = Listener()
    let third = Listener()

    // Prepared, then shown: pending, for this session only.
    _ = requests.prepare(request(0, first), for: "s1")
    #expect(requests.pending(of: "s1") == [github])
    #expect(requests.pending(of: "s2").isEmpty)
    _ = requests.show("s1")
    #expect(requests.pending(of: "s1") == [github])

    // Esc, an error or the timeout: no code, so no longer pending.
    let cancelled = requests.finish(first, signedIn: false)
    #expect(cancelled)
    #expect(requests.pending(of: "s1").isEmpty)

    // A request replaced by another provider's, or one that expires, is pending no more either.
    _ = requests.prepare(request(0, first), for: "s1")
    _ = requests.prepare(request(1, second), for: "s1")
    #expect(requests.pending(of: "s1") == [linear])
    let expired = requests.expire(second, of: "s1")
    #expect(expired)
    #expect(requests.pending(of: "s1").isEmpty)

    // A code keeps it pending for the token exchange that follows, until the session ends.
    _ = requests.prepare(request(0, third), for: "s1")
    _ = requests.show("s1")
    let signedIn = requests.finish(third, signedIn: true)
    #expect(signedIn)
    #expect(requests.pending(of: "s1") == [github])
    _ = requests.prepare(request(1, first), for: "s1")
    #expect(requests.pending(of: "s1") == [github, linear])
    _ = requests.end("s1")
    #expect(requests.pending(of: "s1").isEmpty)

    // Only the prompt's own listener finishes it.
    _ = requests.prepare(request(1, second), for: "s2")
    _ = requests.show("s2")
    let other = requests.finish(first, signedIn: true)
    #expect(!other)
    #expect(requests.pending(of: "s2") == [linear])
}

// MARK: - The callback

@Test func theCallbackIsOneGETOnTheExactPathWithTheSignInsState() {
    let path = "/oauth/callback/r4nd0m"
    func read(_ line: String) -> OAuthCallback { OAuthCallback.read(requestLine: line, path: path, state: "st") }
    #expect(read("GET /oauth/callback/r4nd0m?code=c0de&state=st HTTP/1.1") == .code("c0de"))
    #expect(read("GET /oauth/callback/r4nd0m?state=st&code=a%2Bb HTTP/1.1") == .code("a+b"))
    #expect(
        read("GET /oauth/callback/r4nd0m?error=access_denied&error_description=No%20thanks&state=st HTTP/1.1")
            == .error("access_denied", description: "No thanks"))
    #expect(
        read("GET /oauth/callback/r4nd0m?error=access_denied&state=st HTTP/1.1")
            == .error("access_denied", description: nil))
    // Not the callback: answered with a 404, and the sign-in keeps waiting.
    #expect(read("POST /oauth/callback/r4nd0m?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /oauth/callback/other?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /oauth/callback/r4nd0m/x?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("GET /favicon.ico HTTP/1.1") == .notFound)
    #expect(read("GET http://127.0.0.1/oauth/callback/r4nd0m?code=c&state=st HTTP/1.1") == .notFound)
    #expect(read("garbage") == .notFound)
    #expect(read("") == .notFound)
    // The callback, but not this sign-in's.
    #expect(read("GET /oauth/callback/r4nd0m?code=c&state=other HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?code=c HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?state=st HTTP/1.1") == .invalid, "neither a code nor an error")
    #expect(read("GET /oauth/callback/r4nd0m?code=&state=st HTTP/1.1") == .invalid)
    #expect(read("GET /oauth/callback/r4nd0m?state=st&state=other&code=c HTTP/1.1") == .code("c"), "the first state")
}

@Test func callbackPathsAreRandomAndURLSafe() {
    let tokens = (0..<20).map { _ in OAuthCallback.randomToken() }
    #expect(Set(tokens).count == 20)
    for token in tokens {
        #expect(token.count == 22)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
    #expect(OAuthCallback.page(signedIn: true).contains("Signed in. You can close this tab."))
}

// MARK: - The token store

@Test func tokensAreKeptPerExtensionAndProvider() throws {
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    #expect(OAuthTokenStore.service == "io.github.jakeobsen.fudge.oauth")
    #expect(try store.tokens(extension: "github", provider: "github") == nil)
    let tokens = StoredTokenSet(
        accessToken: "a", refreshToken: "r", expiresIn: 3600, scope: "repo", updatedAt: "2026-11-21T02:00:00Z",
        providerName: "GitHub")
    try store.save(tokens, extension: "github", provider: "github")
    try store.save(
        StoredTokenSet(accessToken: "b", updatedAt: "2026-11-21T03:00:00Z"), extension: "linear", provider: "linear")
    #expect(try secrets.accounts() == ["github/github", "linear/linear"])
    #expect(try store.tokens(extension: "github", provider: "github") == tokens)
    #expect(try store.tokens(extension: "linear", provider: "github") == nil, "another extension's are its own")

    let entries = try store.entries()
    #expect(entries.map(\.id) == ["github/github", "linear/linear"])
    #expect(entries[0].providerName == "GitHub")
    #expect(entries[1].providerName == "linear", "without a name, the provider id")
    #expect(entries[0].updatedAt == ISO8601DateFormatter().date(from: "2026-11-21T02:00:00Z"))

    try store.remove(extension: "github", provider: "github")
    #expect(try store.tokens(extension: "github", provider: "github") == nil)
    try store.removeAll()
    #expect(try store.entries().isEmpty)

    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a/b", provider: "x") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a", provider: "x/y") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "a", provider: "") }
    #expect(throws: OAuthTokenStore.Failure.invalidName) { try store.tokens(extension: "", provider: "x") }
}

@Test func tokensTravelToAndFromTheWorkerAsJSON() {
    let tokens = StoredTokenSet(accessToken: "a", refreshToken: "r", expiresIn: 60, updatedAt: "2026-11-21T02:00:00Z")
    let json = OAuthTokenStore.json(tokens)
    guard case .object(let object) = json else { return #expect(Bool(false), "an object") }
    #expect(object["accessToken"] == .string("a"))
    #expect(object["expiresIn"] == .number(60))
    #expect(OAuthTokenStore.tokenSet(json) == tokens)
    #expect(OAuthTokenStore.tokenSet(.object(["refreshToken": .string("r")])) == nil, "no access token")
}

@Test func anImportKeepsThisMacsSignInServer() {
    #expect(Backup.consentKeys.contains("signInServer") && Backup.consentKeys.contains("signInServerConsentAt"))
    #expect(Backup.exportStrippedKeys.contains("signInServerConsentAt"))
}

// MARK: - The worker's calls

@Test func anExtensionReadsSetsAndRemovesOnlyItsOwnTokens() throws {
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    let theirs = StoredTokenSet(accessToken: "theirs", updatedAt: "2026-11-21T02:00:00Z")
    try store.save(theirs, extension: "other", provider: "github")
    let calls = SignInCalls(store: store, extensionName: "mine", pending: [])
    func call(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
        try calls.answer(method, .object(params))
    }
    // Naming another extension in the parameters changes nothing: the session's extension is used.
    #expect(try call("oauth.tokens.get", ["providerId": .string("github"), "extension": .string("other")]) == .null)
    #expect(throws: OAuthTokenStore.Failure.invalidName) {
        try call("oauth.tokens.get", ["providerId": .string("../other/github")])
    }
    let mine: JSONValue = .object(["accessToken": .string("mine"), "updatedAt": .string("2026-11-21T03:00:00Z")])
    _ = try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": mine, "extension": .string("other")])
    _ = try call("oauth.tokens.remove", ["providerId": .string("github"), "extension": .string("other")])
    #expect(try store.tokens(extension: "other", provider: "github") == theirs, "theirs untouched")
    #expect(try store.tokens(extension: "mine", provider: "github") == nil, "set, then removed: its own")
    _ = try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": mine])
    #expect(try store.tokens(extension: "mine", provider: "github")?.accessToken == "mine")
    #expect(throws: OAuthTokenStore.Failure.invalidTokens) {
        try call("oauth.tokens.set", ["providerId": .string("github"), "tokens": .object([:])])
    }
}

@Test func onlyARelaySignInThisSessionPreparedMarksTokensAndARefreshKeepsTheMark() throws {
    let store = OAuthTokenStore(secrets: MemorySecretStore())
    func tokens(_ relay: String?) -> JSONValue {
        var object: [String: JSONValue] = ["accessToken": .string("a"), "updatedAt": .string("2026-11-21T03:00:00Z")]
        if let relay { object["relayProvider"] = .string(relay) }
        return .object(object)
    }
    let prepared = SignInCalls(store: store, extensionName: "google-ext", pending: ["google"])
    #expect(try prepared.hasRelaySignIn(provider: "google"), "pending")
    _ = try prepared.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens("google")]))
    #expect(try store.tokens(extension: "google-ext", provider: "google")?.relayProvider == "google")

    // A later worker refreshes without a sign-in: the stored mark stays, and it still counts.
    let later = SignInCalls(store: store, extensionName: "google-ext", pending: [])
    #expect(try later.hasRelaySignIn(provider: "google"), "stored")
    _ = try later.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens(nil)]))
    #expect(try store.tokens(extension: "google-ext", provider: "google")?.relayProvider == "google")
    #expect(try !later.hasRelaySignIn(provider: "zoom"))

    // An extension can't claim a relay sign-in it didn't prepare.
    let claims = SignInCalls(store: store, extensionName: "own-flow", pending: [])
    _ = try claims.answer("oauth.tokens.set", .object(["providerId": .string("google"), "tokens": tokens("google")]))
    #expect(try store.tokens(extension: "own-flow", provider: "google")?.relayProvider == nil)
    #expect(try !claims.hasRelaySignIn(provider: "google"))
    // Nor see another extension's.
    #expect(try !SignInCalls(store: store, extensionName: "google", pending: []).hasRelaySignIn(provider: "google"))
}

@Test func onlyThisSignInsCallbackEndsTheWait() {
    #expect(OAuthCallback.code("c").endsWait)
    #expect(OAuthCallback.error("access_denied", description: nil).endsWait)
    #expect(!OAuthCallback.notFound.endsWait, "a wrong path: 404, keep waiting")
    #expect(!OAuthCallback.invalid.endsWait, "a wrong state: 400, keep waiting")
}

// MARK: - Data URLs

@Test func dataURLImagesDecode() {
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"
    let encoded = "data:image/svg+xml,\(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
    #expect(DataURL.image(encoded)?.type == "image/svg+xml")
    #expect(DataURL.image(encoded)?.data == Data(svg.utf8))
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    #expect(DataURL.image("data:image/png;base64,\(png.base64EncodedString())")?.data == png)
    #expect(DataURL.image("data:text/html,<b>x</b>") == nil, "only images")
    #expect(DataURL.image("https://example.com/a.png") == nil)
    #expect(DataURL.image("data:image/png;base64,AAAA", limit: 2) == nil, "past the limit")
}

extension Result {
    fileprivate var failure: Failure? { if case .failure(let failure) = self { failure } else { nil } }
    fileprivate var value: Success? { if case .success(let value) = self { value } else { nil } }
}
