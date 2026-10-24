use RedSourcing;
use Cro::HTTP::Client;
unit module Commerce::WebhookHTTP;

# Kept separate so the simulated demonstration does not load native TLS libraries.
our sub post-webhook(Str $endpoint, Hash $payload, Str :$idempotency-key! --> UInt) is export {
    die Permanent.new(:message('Webhook endpoint must use HTTP or HTTPS'))
        unless $endpoint.starts-with('http://') || $endpoint.starts-with('https://');
    my @headers = 'Idempotency-Key' => $idempotency-key;
    @headers.push('Authorization' => "Bearer {%*ENV<COMMERCE_WEBHOOK_TOKEN>}")
        if %*ENV<COMMERCE_WEBHOOK_TOKEN>;
    my $response;
    {
        CATCH {
            when X::Cro::HTTP::Error { $response = .response }
            default { die Uncertain.new(:message('Webhook response unavailable; receiver may have accepted delivery')) }
        }
        $response = await Cro::HTTP::Client.post($endpoint,
            :body($payload), :content-type<application/json>, :headers(@headers),
            :timeout(10), :!follow);
        await $response.body-blob;
    }
    # Also drain error responses so the request is bounded and connections close.
    await $response.body-blob if $response.status >= 400;
    my UInt $status = $response.status;
    return $status if 200 <= $status < 300;
    die Retryable.new(:message("Webhook returned HTTP $status")) if $status == any(408, 429) || $status >= 500;
    die Permanent.new(:message("Webhook rejected delivery with HTTP $status"));
}
